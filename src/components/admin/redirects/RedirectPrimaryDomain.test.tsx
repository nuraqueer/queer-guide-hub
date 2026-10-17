import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, it, expect, vi } from 'vitest';
import { RedirectPrimaryDomain } from './RedirectPrimaryDomain';
const mocks = vi.hoisted(() => ({ api: vi.fn() }));
vi.mock('@/lib/redirects/memberApi', () => ({ memberRedirectApi: mocks.api }));
const domainId = '00000000-0000-4000-8000-000000000001';
let preference: {
  domainId: string | null;
  hostname: string | null;
  version: string | null;
  ready: boolean;
};
beforeEach(() => {
  vi.clearAllMocks();
  preference = { domainId: null, hostname: null, version: 'version-one', ready: true };
  mocks.api.mockImplementation(
    async (path: string, method?: string, body?: Record<string, unknown>) => {
      if (path.startsWith('/domain-choices'))
        return {
          data: [{ id: domainId, hostname: 'links.community.com' }],
          count: 1,
          nextCursor: null,
          primaryDomainId: preference.domainId,
          primaryUnavailable: !preference.ready,
        };
      if (method === 'PATCH') {
        if (body?.version !== preference.version)
          throw new Error('Primary domain changed; refresh before saving');
        preference = {
          domainId: body.domainId as string | null,
          hostname: body.domainId ? 'links.community.com' : null,
          version: 'version-saved',
          ready: true,
        };
      }
      return preference;
    },
  );
});
function show() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  render(
    <QueryClientProvider client={client}>
      <RedirectPrimaryDomain userId="owner" />
    </QueryClientProvider>,
  );
  return client;
}
describe('versioned primary domain controls', () => {
  it('saves an explicit domain and resets the interactive default without changing any links', async () => {
    show();
    await waitFor(() => expect(screen.getByLabelText('Short-link domain')).toBeEnabled());
    fireEvent.change(screen.getByLabelText('Short-link domain'), { target: { value: domainId } });
    fireEvent.click(screen.getByRole('button', { name: 'Save primary domain' }));
    expect(await screen.findByText('Primary domain saved.')).toBeVisible();
    expect(mocks.api).toHaveBeenCalledWith('/domain-preference', 'PATCH', {
      version: 'version-one',
      domainId,
    });
    expect(screen.getByRole('button', { name: 'Save primary domain' })).toBeDisabled();
    expect(mocks.api.mock.calls.some(([path]) => path.startsWith('/links'))).toBe(false);
  });
  it('initializes a missing workspace preference with an explicit null version', async () => {
    preference = { ...preference, version: null };
    show();
    await waitFor(() => expect(screen.getByLabelText('Short-link domain')).toBeEnabled());
    fireEvent.change(screen.getByLabelText('Short-link domain'), { target: { value: domainId } });
    fireEvent.click(screen.getByRole('button', { name: 'Save primary domain' }));
    expect(await screen.findByText('Primary domain saved.')).toBeVisible();
    expect(mocks.api).toHaveBeenCalledWith('/domain-preference', 'PATCH', {
      version: null,
      domainId,
    });
  });
  it('retains a missing-row version through refresh and further editing', async () => {
    preference = { ...preference, version: null };
    const client = show();
    await waitFor(() => expect(screen.getByLabelText('Short-link domain')).toBeEnabled());
    fireEvent.change(screen.getByLabelText('Short-link domain'), { target: { value: domainId } });
    preference = { ...preference, version: 'concurrent-initialization' };
    await client.invalidateQueries({ queryKey: ['redirect-domain-preference', 'owner'] });
    fireEvent.change(screen.getByLabelText('Short-link domain'), { target: { value: '' } });
    fireEvent.change(screen.getByLabelText('Short-link domain'), { target: { value: domainId } });
    fireEvent.click(screen.getByRole('button', { name: 'Save primary domain' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Primary domain changed');
    expect(mocks.api).toHaveBeenCalledWith('/domain-preference', 'PATCH', {
      version: null,
      domainId,
    });
  });
  it('retains the editing version when a concurrent refresh changes the primary', async () => {
    const client = show();
    await waitFor(() => expect(screen.getByLabelText('Short-link domain')).toBeEnabled());
    fireEvent.change(screen.getByLabelText('Short-link domain'), { target: { value: domainId } });
    preference = { ...preference, version: 'concurrent-version' };
    await client.invalidateQueries({ queryKey: ['redirect-domain-preference', 'owner'] });
    fireEvent.click(screen.getByRole('button', { name: 'Save primary domain' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Primary domain changed');
    expect(mocks.api).toHaveBeenCalledWith('/domain-preference', 'PATCH', {
      version: 'version-one',
      domainId,
    });
  });
  it('preserves the unavailable saved primary until the owner explicitly chooses an available domain', async () => {
    preference = {
      domainId: 'unavailable-domain',
      hostname: 'lost.community.com',
      version: 'version-one',
      ready: false,
    };
    show();
    expect(
      await screen.findByText(
        'The saved primary domain is unavailable. New links require an explicit available domain choice.',
      ),
    ).toBeVisible();
    await waitFor(() => expect(screen.getByLabelText('Short-link domain')).toBeEnabled());
    expect(screen.getByLabelText('Short-link domain')).toHaveValue('unavailable-domain');
    expect(screen.getByRole('button', { name: 'Save primary domain' })).toBeDisabled();
    fireEvent.change(screen.getByLabelText('Short-link domain'), { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save primary domain' }));
    expect(await screen.findByText('Primary domain saved.')).toBeVisible();
    expect(mocks.api).toHaveBeenCalledWith('/domain-preference', 'PATCH', {
      version: 'version-one',
      domainId: null,
    });
  });
});
