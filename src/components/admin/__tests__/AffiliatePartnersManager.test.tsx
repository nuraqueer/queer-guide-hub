/**
 * @vitest-environment jsdom
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { renderWithProviders, screen, fireEvent } from '@/test/test-utils';

const { useAffiliateMock } = vi.hoisted(() => ({ useAffiliateMock: vi.fn() }));

vi.mock('sonner', () => ({ toast: Object.assign(vi.fn(), { success: vi.fn(), error: vi.fn() }) }));
vi.mock('@/hooks/useAffiliateLinks', () => ({ useAffiliateLinks: useAffiliateMock }));

import { AffiliatePartnersManager } from '../AffiliatePartnersManager';

beforeEach(() => {
  useAffiliateMock.mockReset();
  useAffiliateMock.mockReturnValue({
    partners: [
      { id: 'p1', partner_name: 'Booking.com', domains: ['booking.com'], url_patterns: [], parameters: {}, redirect_template: '', enabled: true },
    ],
    loading: false, error: null,
    fetchPartners: vi.fn(), createPartner: vi.fn(), updatePartner: vi.fn(), deletePartner: vi.fn(),
  });
});

describe('AffiliatePartnersManager', () => {
  it('renders partner rows', () => {
    renderWithProviders(<AffiliatePartnersManager />);
    expect(screen.getByText('Booking.com')).toBeInTheDocument();
  });

  it('opens dialog on Add', () => {
    renderWithProviders(<AffiliatePartnersManager />);
    fireEvent.click(screen.getByRole('button', { name: 'Add Partner' }));
    expect(screen.getByRole('dialog', { name: 'Add Affiliate Partner' })).toBeInTheDocument();
    expect(screen.getByLabelText('Partner Name *')).toHaveValue('');
  });
});
