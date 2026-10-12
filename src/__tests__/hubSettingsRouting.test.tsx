/** @vitest-environment jsdom */
import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MemoryRouter, useLocation } from 'react-router';

vi.mock('react-i18next', () => ({
  useTranslation: () => ({
    t: (_key: string, fallback?: string) => fallback ?? _key,
    i18n: { language: 'en', changeLanguage: () => {} },
  }),
}));
vi.mock('@/providers/SearchTelemetryProvider', () => ({ useSearchTelemetry: () => {} }));
vi.mock('@/components/security/AdminRouteGuard', () => ({
  AdminRouteGuard: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}));
vi.mock('@/components/layout/RouteFade', () => ({
  RouteFade: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}));
vi.mock('@/pages/hub/HubPage', () => ({
  default: ({ module }: { module: string }) => <div>HUB_MODULE:{module}</div>,
}));
vi.mock('@/pages/NotFound', () => ({ default: () => <div>NOT_FOUND</div> }));

import { AppRoutes } from '@/routes';

function LocationProbe() {
  const { pathname, search, hash } = useLocation();
  return (
    <output data-testid="location">
      {pathname}
      {search}
      {hash}
    </output>
  );
}

describe('hub settings routing', () => {
  it.each([
    ['/hub/settings', '/hub/settings'],
    ['/de/hub/settings', '/de/hub/settings'],
    [
      '/settings?section=privacy#settings-section-privacy',
      '/hub/settings?section=privacy#settings-section-privacy',
    ],
    ['/de/settings?tab=dating', '/de/hub/settings?tab=dating'],
    ['/profile/settings?tab=identity', '/hub/settings?tab=identity'],
    ['/ar/profile/settings?section=account', '/ar/hub/settings?section=account'],
    ['/me/settings?section=avatar', '/hub/settings?section=avatar'],
    ['/de/me/settings?section=travel', '/de/hub/settings?section=travel'],
    ['/settings/privacy?from=profile', '/hub/settings?from=profile&section=privacy'],
    [
      '/de/settings/privacy?section=account&tab=dating#privacy',
      '/de/hub/settings?section=privacy&tab=dating#privacy',
    ],
  ])('resolves %s to the settings module at %s', async (source, target) => {
    render(
      <MemoryRouter initialEntries={[source]}>
        <AppRoutes />
        <LocationProbe />
      </MemoryRouter>,
    );
    expect(await screen.findByText('HUB_MODULE:settings')).toBeTruthy();
    expect(screen.getByTestId('location')).toHaveTextContent(target);
    expect(screen.queryByText('NOT_FOUND')).toBeNull();
  });
});
