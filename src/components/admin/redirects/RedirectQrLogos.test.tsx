import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_QR_STYLE } from '@/lib/redirects/qr';
import type { QrStylePreference } from '@/lib/redirects/qrPreferences';
import { manualRedirect } from '@/lib/redirects/inventory';
import { RedirectQrStyleSettings } from './RedirectQrStyleSettings';
import { QrExport } from './RedirectQrDialog';
import { RedirectBulkQrDialog } from './RedirectBulkQrDialog';
const mocks = vi.hoisted(() => ({
  api: vi.fn(),
  load: vi.fn(),
  read: vi.fn(),
  generate: vi.fn(),
  build: vi.fn(),
  user: 'owner',
}));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: mocks.user } }) }));
vi.mock('@/lib/redirects/memberApi', () => ({ memberRedirectApi: mocks.api }));
vi.mock('@/lib/redirects/qrLogos', async (original) => ({
  ...(await original<typeof import('@/lib/redirects/qrLogos')>()),
  loadQrLogo: mocks.load,
  readQrLogoFile: mocks.read,
}));
vi.mock('@/lib/redirects/qr', async (original) => ({
  ...(await original<typeof import('@/lib/redirects/qr')>()),
  generateQr: mocks.generate,
}));
vi.mock('@/lib/redirects/qrBundle', () => ({ buildQrBundle: mocks.build }));
// Export hooks are mocked at the hydrated boundary; byte validation has separate real-raster tests.
vi.mock('@/hooks/useRedirectQrStyle', () => ({
  useRedirectQrStyle: (_id: string, skip: boolean) => ({
    isSuccess: true,
    isError: false,
    isFetching: false,
    refetch: vi.fn(),
    data: {
      style: {
        ...DEFAULT_QR_STYLE,
        ...(!skip ? { logo: 'data:image/png;base64,c2F2ZWQ=', logoIdentity: 'saved:a' } : {}),
      },
      source: 'domain',
    },
  }),
}));
vi.mock('@/hooks/useRedirectBulkQrStyles', () => ({
  useRedirectBulkQrStyles: (rows: { id: string }[], skip: boolean) => ({
    isSuccess: true,
    isError: false,
    isFetching: false,
    refetch: vi.fn(),
    data: new Map(
      rows.map((row, index) => [
        row.id,
        {
          ...DEFAULT_QR_STYLE,
          ...(!skip
            ? {
                logo: 'data:image/png;base64,' + btoa('saved:' + index),
                logoIdentity: 'saved:' + index,
              }
            : {}),
        },
      ]),
    ),
  }),
}));
// Exported QR ink is deliberately independent of the admin theme.
// eslint-disable-next-line no-restricted-syntax
const exportInk = '#221144';
const asset = {
  id: 'asset',
  key: 'asset.png',
  url: 'https://fixture.example/asset.png',
  mime: 'image/png' as const,
  bytes: 10,
  width: 64,
  height: 64,
  sha256: 'digest',
};
let stored: QrStylePreference;
function show(element: React.ReactNode) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return {
    client,
    ...render(<QueryClientProvider client={client}>{element}</QueryClientProvider>),
  };
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.user = 'owner';
  stored = {
    version: 'v1',
    style: {},
    effectiveStyle: DEFAULT_QR_STYLE,
    domainId: 'domain',
    logoMode: 'custom',
    logoAsset: asset,
    effectiveLogo: asset,
    logoSource: 'domain',
  };
  mocks.load.mockResolvedValue('data:image/png;base64,c2F2ZWQ=');
  mocks.read.mockResolvedValue({ data: 'data:image/png;base64,bG9jYWw=', image: 'bG9jYWw=' });
  mocks.api.mockImplementation(async (_path, method, body) => {
    if (method !== 'GET') {
      if (body.version !== stored.version)
        throw new Error('QR style changed; reload before saving');
      stored = {
        ...stored,
        version: 'v2',
        ...(body.clearLogo
          ? { logoMode: 'inherit', logoAsset: null, effectiveLogo: null }
          : body.image
            ? { logoMode: 'custom' }
            : { logoMode: body.logoMode }),
      };
    }
    return structuredClone(stored);
  });
  mocks.generate.mockResolvedValue({
    png: 'data:image/png;base64,cXI=',
    jpg: 'data:image/jpeg;base64,cXI=',
    svg: '<svg/>',
  });
  mocks.build.mockResolvedValue({
    bytes: new Uint8Array([80, 75]).buffer,
    count: 2,
    firstPreview: 'data:image/png;base64,cXI=',
  });
});
describe('saved logo owner controls', () => {
  it('uploads only after review with the version captured at file selection', async () => {
    const view = show(<RedirectQrStyleSettings domainId="domain" />);
    const input = await screen.findByLabelText('Upload saved QR logo');
    fireEvent.change(input, { target: { files: [new File(['png'], 'logo.png')] } });
    await waitFor(() => expect(screen.getByRole('button', { name: 'Save QR logo' })).toBeEnabled());
    expect(mocks.api.mock.calls.every((call) => call[1] === 'GET')).toBe(true);
    stored = { ...stored, version: 'other-owner-version' };
    await act(() => view.client.invalidateQueries({ queryKey: ['redirect-qr-preference'] }));
    fireEvent.click(screen.getByRole('button', { name: 'Save QR logo' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('reload before saving');
    expect(mocks.api).toHaveBeenLastCalledWith('/qr-styles/domains/domain/logo', 'POST', {
      version: 'v1',
      image: 'bG9jYWw=',
    });
    fireEvent.click(screen.getByRole('button', { name: 'Reload QR settings' }));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Save QR logo' })).toBeDisabled(),
    );
  });
  it('retains custom artwork when hiding, supports reuse and reviews clearing separately', async () => {
    show(<RedirectQrStyleSettings domainId="domain" />);
    fireEvent.change(await screen.findByLabelText('Saved QR logo choice'), {
      target: { value: 'none' },
    });
    expect(screen.getByRole('button', { name: 'Reset QR overrides' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Save QR logo' }));
    await screen.findByText('Saved QR logo.');
    expect(stored.logoAsset).toEqual(asset);
    expect(mocks.api).toHaveBeenCalledWith('/qr-styles/domains/domain', 'PATCH', {
      version: 'v1',
      logoMode: 'none',
    });
    fireEvent.change(screen.getByLabelText('Saved QR logo choice'), {
      target: { value: 'custom' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Save QR logo' }));
    await waitFor(() => expect(stored.logoMode).toBe('custom'));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Clear saved logo' })).toBeEnabled(),
    );
    fireEvent.click(screen.getByRole('button', { name: 'Clear saved logo' }));
    expect(stored.logoAsset).toEqual(asset);
    fireEvent.click(screen.getByRole('button', { name: 'Confirm clear logo' }));
    await waitFor(() => expect(stored.logoAsset).toBeNull());
    expect(mocks.api).toHaveBeenLastCalledWith('/qr-styles/domains/domain', 'PATCH', {
      version: 'v2',
      clearLogo: true,
    });
  });
  it('discards another account’s unsaved logo and blocks logo changes while appearance is dirty', async () => {
    const view = show(<RedirectQrStyleSettings />);
    fireEvent.change(await screen.findByLabelText('Saved QR logo choice'), {
      target: { value: 'none' },
    });
    mocks.user = 'second';
    view.rerender(
      <QueryClientProvider client={view.client}>
        <RedirectQrStyleSettings />
      </QueryClientProvider>,
    );
    await waitFor(() =>
      expect(screen.getByLabelText('Saved QR logo choice')).toHaveValue('custom'),
    );
    expect(screen.getByRole('button', { name: 'Save QR logo' })).toBeDisabled();
    mocks.user = 'owner';
    view.rerender(
      <QueryClientProvider client={view.client}>
        <RedirectQrStyleSettings />
      </QueryClientProvider>,
    );
    await waitFor(() =>
      expect(screen.getByLabelText('Saved QR logo choice')).toHaveValue('custom'),
    );
    expect(screen.getByLabelText('QR dots')).toBeEnabled();

    fireEvent.change(screen.getByLabelText('QR dots'), { target: { value: 'joined' } });
    expect(screen.getByLabelText('Upload saved QR logo')).toBeDisabled();
  });
});
describe('export logo precedence', () => {
  it('keeps saved artwork under appearance edits, hides explicitly and restores it without large cache keys', async () => {
    const view = show(<QrExport url="https://queer.guide/go/logo" />);
    await screen.findByRole('img');
    fireEvent.change(screen.getByLabelText('QR dots'), { target: { value: 'joined' } });
    await waitFor(() =>
      expect(mocks.generate).toHaveBeenLastCalledWith(
        expect.any(String),
        expect.objectContaining({ dots: 'joined', logo: 'data:image/png;base64,c2F2ZWQ=' }),
        expect.anything(),
      ),
    );
    fireEvent.click(screen.getByLabelText('Hide logos for this export'));
    await waitFor(() => expect(mocks.generate.mock.calls.at(-1)?.[1].logo).toBeUndefined());
    fireEvent.click(screen.getByRole('button', { name: 'Use saved logo' }));
    await waitFor(() =>
      expect(screen.getByLabelText('Hide logos for this export')).not.toBeChecked(),
    );
    expect(
      JSON.stringify(
        view.client
          .getQueryCache()
          .getAll()
          .map((query) => query.queryKey),
      ),
    ).not.toContain('data:image');
  });
  it('preserves two different saved logos with common colors, then overrides and hides both explicitly', async () => {
    const rows = ['one', 'two'].map((id) =>
      manualRedirect({ id, type: 'SHORT', slug: id, target: '/events', is_enabled: true }),
    );
    show(<RedirectBulkQrDialog rows={rows} onClose={() => {}} />);
    fireEvent.change(screen.getByLabelText('QR dot color'), { target: { value: exportInk } });
    fireEvent.click(screen.getByRole('button', { name: 'Prepare QR ZIP' }));
    await waitFor(() => expect(mocks.build).toHaveBeenCalledOnce());
    const map = mocks.build.mock.calls[0][3].stylesById;
    expect(map.get(rows[0].id).foreground).toBe(exportInk);
    expect(map.get(rows[1].id).foreground).toBe(exportInk);
    expect(map.get(rows[0].id).logo).not.toBe(map.get(rows[1].id).logo);
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Prepare QR ZIP' })).toBeEnabled(),
    );
    fireEvent.change(screen.getByLabelText('QR logo'), {
      target: { files: [new File(['png'], 'local.png')] },
    });
    await waitFor(() =>
      expect(screen.getByText('Your uploaded logo applies to this export.')).toBeVisible(),
    );
    expect(screen.getByRole('button', { name: 'Download QR ZIP' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Prepare QR ZIP' }));
    await waitFor(() => expect(mocks.build).toHaveBeenCalledTimes(2));
    for (const style of mocks.build.mock.calls[1][3].stylesById.values())
      expect(style.logo).toBe('data:image/png;base64,bG9jYWw=');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Prepare QR ZIP' })).toBeEnabled(),
    );
    fireEvent.click(screen.getByLabelText('Hide logos for this export'));
    fireEvent.click(screen.getByRole('button', { name: 'Prepare QR ZIP' }));
    await waitFor(() => expect(mocks.build).toHaveBeenCalledTimes(3));
    for (const style of mocks.build.mock.calls[2][3].stylesById.values())
      expect(style.logo).toBeUndefined();
  });
});
