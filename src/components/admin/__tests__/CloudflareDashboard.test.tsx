/** @vitest-environment jsdom */
import type { ReactNode } from 'react';
import type {
  CloudflareAnalytics,
  CloudflareZoneInfo,
  CloudflareSecuritySettings,
  CloudflarePerformanceSettings,
} from '@/integrations/supabase/cloudflare';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import { toast } from 'sonner';
import { cloudflareAPI } from '@/integrations/supabase/cloudflare';

vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
vi.mock('@/components/admin/frames/AdminArchetypeHeader', () => ({
  AdminArchetypeHeader: ({
    title,
    filters,
    actions,
  }: {
    title: ReactNode;
    filters: ReactNode;
    actions: ReactNode;
  }) => (
    <header>
      <h1>{title}</h1>
      {filters}
      {actions}
    </header>
  ),
}));
vi.mock('@/integrations/supabase/cloudflare', () => ({
  cloudflareAPI: {
    getAnalytics: vi.fn(),
    getZoneInfo: vi.fn(),
    getSecuritySettings: vi.fn(),
    getPerformanceSettings: vi.fn(),
  },
}));
import { CloudflareDashboard } from '../CloudflareDashboard';

beforeEach(() => {
  cleanup();
  vi.clearAllMocks();
  vi.mocked(cloudflareAPI.getZoneInfo).mockResolvedValue({
    success: true,
    result: { name: 'queer.guide', status: 'active', name_servers: [], development_mode: 0 },
  } as CloudflareZoneInfo);
  vi.mocked(cloudflareAPI.getAnalytics).mockResolvedValue({
    success: true,
    result: { totals: { requests: { all: 123 }, uniques: { all: 10 } } },
  } as CloudflareAnalytics);
  vi.mocked(cloudflareAPI.getSecuritySettings).mockResolvedValue({
    success: true,
    result: {},
  } as CloudflareSecuritySettings);
  vi.mocked(cloudflareAPI.getPerformanceSettings).mockResolvedValue({
    success: true,
    result: {},
  } as CloudflarePerformanceSettings);
});

describe('CloudflareDashboard', () => {
  it('loads healthy sections even when the zone request fails', async () => {
    vi.mocked(cloudflareAPI.getZoneInfo).mockRejectedValue(
      new Error('Zone read permission missing'),
    );
    render(<CloudflareDashboard />);
    expect(await screen.findByRole('alert')).toHaveTextContent('Zone read permission missing');
    expect(screen.getByText('123')).toBeInTheDocument();
    expect(cloudflareAPI.getSecuritySettings).toHaveBeenCalled();
  });

  it('shows persistent errors and does not report successful refreshes for failed sections', async () => {
    vi.mocked(cloudflareAPI.getAnalytics).mockRejectedValue(
      new Error('Analytics permission missing'),
    );
    render(<CloudflareDashboard />);
    expect(await screen.findByRole('alert')).toHaveTextContent('Analytics permission missing');
    expect(screen.getByText('Analytics data unavailable')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));
    await waitFor(() =>
      expect(toast.error).toHaveBeenCalledWith(
        'Cloudflare refresh incomplete. See the errors below.',
      ),
    );
    expect(toast.success).not.toHaveBeenCalled();
  });

  it('clears prior errors after a successful retry', async () => {
    vi.mocked(cloudflareAPI.getAnalytics).mockRejectedValueOnce(
      new Error('Temporarily unavailable'),
    );
    render(<CloudflareDashboard />);
    await screen.findByRole('alert');
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));
    await waitFor(() => expect(toast.success).toHaveBeenCalledWith('Cloudflare data refreshed.'));
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });
});
