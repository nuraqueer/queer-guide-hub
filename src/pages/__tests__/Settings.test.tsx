/** @vitest-environment jsdom */
import { afterEach, beforeEach, describe, it, expect, vi } from 'vitest';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Link } from 'react-router';

const state = vi.hoisted(() => ({ updateProfile: vi.fn(), navigate: vi.fn() }));
vi.mock('@/hooks/useLocalizedNavigate', () => ({ useLocalizedNavigate: () => state.navigate }));
vi.mock('@/hooks/useAuth', () => ({
  useAuth: () => ({ user: { id: 'u1', email: 'alex@example.com' }, hasPasskey: false }),
}));
vi.mock('@/hooks/useProfile', () => ({
  useProfile: () => ({ updateProfile: state.updateProfile, refetchProfile: vi.fn() }),
}));
vi.mock('@/hooks/useProfileData', () => ({
  useProfileData: () => ({ profile: null, isLoading: false, profileLoading: false }),
}));
vi.mock('@/hooks/use-toast', () => ({ useToast: () => ({ toast: vi.fn() }) }));
vi.mock('@/components/profile/settings/BasicInfoTab', () => ({
  BasicInfoTab: ({
    formData,
    onChange,
  }: {
    formData: { bio: string };
    onChange: (field: string, value: string) => void;
  }) => (
    <input
      aria-label="Bio"
      value={formData.bio}
      onChange={(event) => onChange('bio', event.target.value)}
    />
  ),
}));
vi.mock('@/components/profile/settings/IdentityTab', () => ({
  IdentityTab: () => <div>Identity editor</div>,
}));
vi.mock('@/components/profile/settings/PrivacyTab', () => ({
  PrivacyTab: () => <div>Privacy editor</div>,
}));
vi.mock('@/components/profile/settings/DangerZone', () => ({ DangerZone: () => null }));
vi.mock('@/components/profile/IntimateTab', () => ({ IntimateTab: () => null }));
vi.mock('@/components/profile/TravelPreferencesEditor', () => ({
  TravelPreferencesEditor: () => null,
}));
vi.mock('@/components/status/StatusEditor', () => ({ StatusEditor: () => null }));
vi.mock('@/components/profile/IdentityPreviewCard', () => ({ IdentityPreviewCard: () => null }));
vi.mock('@/components/profile/AvatarChooser', () => ({
  AvatarChooser: () => <div>Avatar editor</div>,
}));
vi.mock('@/components/profile/UsernamePanel', () => ({ UsernamePanel: () => null }));
vi.mock('@/components/profile/ChangePasswordPanel', () => ({ ChangePasswordPanel: () => null }));
vi.mock('@/components/profile/PreferencesMirrorCard', () => ({
  PreferencesMirrorCard: () => null,
}));
vi.mock('@/components/profile/TravelForwardingSettings', () => ({
  TravelForwardingSettings: () => null,
}));
vi.mock('@/components/profile/PushNotificationSettings', () => ({
  PushNotificationSettings: () => null,
}));
vi.mock('@/components/trips/DocumentsList', () => ({ DocumentsList: () => null }));

import Settings from '../Settings';

function renderAt(path = '/hub/settings') {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Settings />
      <Link to="/hub/settings?section=privacy">Open privacy</Link>
    </MemoryRouter>,
  );
}

describe('Settings workspace', () => {
  beforeEach(() => {
    state.updateProfile.mockReset().mockResolvedValue({ error: null });
  });
  afterEach(() => vi.useRealTimers());

  it('renders a hub header and save feedback without a separate Back action', () => {
    renderAt();
    expect(screen.getByRole('heading', { name: 'Settings' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Back' })).toBeNull();
    expect(screen.getByRole('status')).toHaveTextContent('All changes saved');
  });

  it.each([
    ['?section=privacy', 'Privacy editor'],
    ['?tab=identity', 'Identity editor'],
    ['?section=avatar', 'Avatar editor'],
  ])('preserves the %s editor deep link', (query, editor) => {
    renderAt(`/hub/settings${query}`);
    expect(screen.getByText(editor)).toBeTruthy();
  });

  it('follows a new section link within the mounted workspace and keeps only one editor open', () => {
    renderAt('/hub/settings?section=profile');
    expect(screen.getByRole('textbox', { name: 'Bio' })).toBeTruthy();
    fireEvent.click(screen.getByRole('link', { name: 'Open privacy' }));
    expect(screen.getByText('Privacy editor')).toBeTruthy();
    expect(screen.queryByRole('textbox', { name: 'Bio' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: /^Profile Bio/ }));
    expect(screen.getByRole('textbox', { name: 'Bio' })).toBeTruthy();
    expect(screen.queryByText('Privacy editor')).toBeNull();
  });

  it('debounces profile changes and reports a successful autosave', async () => {
    vi.useFakeTimers();
    renderAt('/hub/settings?section=profile');
    fireEvent.change(screen.getByRole('textbox', { name: 'Bio' }), {
      target: { value: 'My updated bio' },
    });
    expect(screen.getByRole('status')).toHaveTextContent('Unsaved changes');
    expect(state.updateProfile).not.toHaveBeenCalled();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(3000);
    });
    expect(state.updateProfile).toHaveBeenCalledTimes(1);
    expect(state.updateProfile).toHaveBeenCalledWith(
      expect.objectContaining({ bio: 'My updated bio' }),
    );
    expect(screen.getByRole('status')).toHaveTextContent('All changes saved');
  });
});
