import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectPasswordBranding } from './RedirectPasswordBranding';
const fixture = vi.hoisted(() => ({ account: 'owner', request: vi.fn() }));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: fixture.account } }) }));
vi.mock('@/lib/redirects/memberApi', () => ({
  memberRedirectApi: (...args: unknown[]) => fixture.request(...args),
}));
vi.mock('@/lib/redirects/qrLogos', () => ({
  readQrLogoFile: async () => ({ data: 'data:image/png;base64,AAAA', image: 'AAAA' }),
  loadQrLogo: async () => 'data:image/png;base64,BBBB',
}));
const link = 'd0000000-0000-4000-8000-000000000001',
  v1 = 'e0000000-0000-4000-8000-000000000001',
  v2 = 'f0000000-0000-4000-8000-000000000001';
const profile = {
  linkId: link,
  version: v1,
  updatedAt: null,
  brandName: 'Community',
  logoAsset: null,
  canEdit: true,
};
function show() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const tree = () => (
    <QueryClientProvider client={client}>
      <RedirectPasswordBranding linkId={link} />
    </QueryClientProvider>
  );
  const view = render(tree());
  return { view, client, tree };
}
beforeEach(() => {
  fixture.account = 'owner';
  fixture.request.mockReset();
  fixture.request.mockResolvedValue(profile);
});
describe('password-page branding editor', () => {
  it('prefills the public label and preserves the current version on save', async () => {
    const { view } = show();
    expect(await screen.findByLabelText('Public brand name')).toHaveValue('Community');
    fixture.request.mockImplementation(
      async (_path: string, method: string, body: { brandName: string }) =>
        method === 'PATCH' ? { ...profile, version: v2, brandName: body.brandName } : profile,
    );
    fireEvent.change(screen.getByLabelText('Public brand name'), {
      target: { value: 'Updated label' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Save public name' }));
    await screen.findByText('Password-page branding saved.');
    expect(fixture.request).toHaveBeenCalledWith(
      '/links/' + link + '/password-branding',
      'PATCH',
      { version: v1, brandName: 'Updated label' },
      expect.any(AbortSignal),
    );
    view.unmount();
  });
  it('preserves a stale draft and disables saving until explicit reload', async () => {
    const { view, client } = show();
    await screen.findByLabelText('Public brand name');
    fireEvent.change(screen.getByLabelText('Public brand name'), { target: { value: 'My edit' } });
    client.setQueryData(['redirect-password-branding', 'owner', link], {
      ...profile,
      version: v2,
      brandName: 'Concurrent edit',
    });
    await screen.findByText('Branding changed while you were editing. Reload before saving.');
    expect(screen.getByLabelText('Public brand name')).toHaveValue('My edit');
    expect(screen.getByRole('button', { name: 'Save public name' })).toBeDisabled();
    fixture.request.mockResolvedValue({ ...profile, version: v2, brandName: 'Concurrent edit' });
    fireEvent.click(screen.getByRole('button', { name: 'Reload settings' }));
    await waitFor(() =>
      expect(screen.getByLabelText('Public brand name')).toHaveValue('Concurrent edit'),
    );
    view.unmount();
  });
  it('uploads the logo independently and keeps an unsaved name against the new version', async () => {
    const { view } = show();
    await screen.findByLabelText('Public brand name');
    fixture.request.mockImplementation(
      async (path: string, method: string, body: { brandName: string }) =>
        path.endsWith('/logo')
          ? { ...profile, version: v2, logoAsset: { id: 'asset', sha256: 'hash' } }
          : method === 'PATCH'
            ? {
                ...profile,
                version: 'a0000000-0000-4000-8000-000000000001',
                brandName: body.brandName,
              }
            : profile,
    );
    fireEvent.change(screen.getByLabelText('Public brand name'), {
      target: { value: 'Unsaved name' },
    });
    fireEvent.change(screen.getByLabelText('Choose a password-page logo'), {
      target: { files: [new File(['logo'], 'logo.png', { type: 'image/png' })] },
    });
    fireEvent.click(await screen.findByRole('button', { name: 'Upload selected logo' }));
    await screen.findByText('Password-page logo saved.');
    expect(screen.getByLabelText('Public brand name')).toHaveValue('Unsaved name');
    expect(fixture.request.mock.calls.filter(([, method]) => method === 'PATCH')).toHaveLength(0);
    fireEvent.click(screen.getByRole('button', { name: 'Save public name' }));
    await screen.findByText('Password-page branding saved.');
    expect(fixture.request).toHaveBeenCalledWith(
      '/links/' + link + '/password-branding',
      'PATCH',
      { version: v2, brandName: 'Unsaved name' },
      expect.any(AbortSignal),
    );
    view.unmount();
  });
  it('shows published branding to a viewer while withholding edit controls', async () => {
    fixture.request.mockResolvedValue({ ...profile, canEdit: false });
    const { view } = show();
    expect(await screen.findByLabelText('Public brand name')).toBeDisabled();
    expect(screen.queryByLabelText('Choose a password-page logo')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Save public name' })).not.toBeInTheDocument();
    view.unmount();
  });
  it('aborts a late upload when the account changes without restoring its draft', async () => {
    const { view, tree } = show();
    await screen.findByLabelText('Public brand name');
    let finish: (value: unknown) => void = () => {};
    let signal: AbortSignal | undefined;
    fixture.request.mockImplementation(
      async (path: string, _method: string, _body: unknown, currentSignal: AbortSignal) => {
        if (path.endsWith('/logo')) {
          signal = currentSignal;
          return new Promise((resolve) => {
            finish = resolve;
          });
        }
        return {
          ...profile,
          brandName: fixture.account === 'owner' ? 'Community' : 'Second account',
          canEdit: fixture.account === 'owner',
        };
      },
    );
    fireEvent.change(screen.getByLabelText('Choose a password-page logo'), {
      target: { files: [new File(['logo'], 'logo.png', { type: 'image/png' })] },
    });
    fireEvent.click(await screen.findByRole('button', { name: 'Upload selected logo' }));
    await waitFor(() => expect(signal).toBeDefined());
    fixture.account = 'other-owner';
    view.rerender(tree());
    await waitFor(() =>
      expect(screen.getByLabelText('Public brand name')).toHaveValue('Second account'),
    );
    expect(signal?.aborted).toBe(true);
    finish({ ...profile, version: v2, brandName: 'Late old account' });
    await waitFor(() =>
      expect(screen.getByLabelText('Public brand name')).toHaveValue('Second account'),
    );
    expect(screen.queryByText('Password-page logo saved.')).not.toBeInTheDocument();
    view.unmount();
  });
});
