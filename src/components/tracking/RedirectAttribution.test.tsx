import { act, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, useLocation } from 'react-router';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectAttribution } from './RedirectAttribution';
import { readRedirectAttribution } from '@/lib/redirects/attribution';
const mocks = vi.hoisted(() => ({
  allowed: true,
  user: null as Record<string, unknown> | null,
  invoke: vi.fn(),
  listener: null as ((allowed: boolean) => void) | null,
}));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: mocks.user }) }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
vi.mock('@/lib/analyticsConsent', () => ({
  analyticsAllowed: () => mocks.allowed,
  onAnalyticsConsentChange: (callback: (allowed: boolean) => void) => {
    mocks.listener = callback;
    return () => {
      mocks.listener = null;
    };
  },
}));
const click = '00000000-0000-4000-8000-000000000001';
function Location() {
  const location = useLocation();
  return <p>{location.pathname + location.search + location.hash}</p>;
}
function show() {
  return render(
    <MemoryRouter initialEntries={['/events?utm_source=qr&qg_click_id=' + click + '#details']}>
      <RedirectAttribution />
      <Location />
    </MemoryRouter>,
  );
}
beforeEach(() => {
  localStorage.clear();
  vi.clearAllMocks();
  mocks.allowed = true;
  mocks.user = null;
  mocks.invoke.mockResolvedValue({ data: { id: 'lead' }, error: null });
});
describe('native attribution lifecycle', () => {
  it('captures only with consent, keeps campaign values and fragment, and cleans the click ID from the visible URL', async () => {
    show();
    expect(await screen.findByText('/events?utm_source=qr#details')).toBeVisible();
    expect(readRedirectAttribution(true)?.clickId).toBe(click);
    expect(mocks.invoke).not.toHaveBeenCalled();
    act(() => {
      mocks.allowed = false;
      mocks.listener?.(false);
    });
    expect(readRedirectAttribution(true)).toBeNull();
  });
  it('makes no storage write or conversion call when effective analytics permission is absent', () => {
    mocks.allowed = false;
    show();
    expect(readRedirectAttribution(true)).toBeNull();
    expect(mocks.invoke).not.toHaveBeenCalled();
    expect(
      screen.getByText('/events?utm_source=qr&qg_click_id=' + click + '#details'),
    ).toBeVisible();
  });
  it('sends only an attributed click for a new confirmed account, then stops future writes on consent withdrawal', async () => {
    mocks.user = {
      id: 'new-user',
      created_at: new Date().toISOString(),
      email_confirmed_at: new Date().toISOString(),
      is_anonymous: false,
    };
    show();
    await waitFor(() => expect(mocks.invoke).toHaveBeenCalledTimes(1));
    expect(mocks.invoke.mock.calls[0]).toMatchObject([
      'redirect-api/native/signup',
      { body: { clickId: click } },
    ]);
    act(() => {
      mocks.allowed = false;
      mocks.listener?.(false);
    });
    expect(readRedirectAttribution(true)).toBeNull();
    expect(mocks.invoke).toHaveBeenCalledTimes(1);
  });
  it('does not report anonymous accounts as confirmed signups', async () => {
    mocks.user = {
      id: 'anonymous',
      created_at: new Date().toISOString(),
      email_confirmed_at: new Date().toISOString(),
      is_anonymous: true,
    };
    show();
    await screen.findByText('/events?utm_source=qr#details');
    expect(mocks.invoke).not.toHaveBeenCalled();
  });
});
