import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_QR_STYLE } from '@/lib/redirects/qr';
import { RedirectQrStyleSettings } from './RedirectQrStyleSettings';
import { QrExport } from './RedirectQrDialog';
import { RedirectBulkQrDialog } from './RedirectBulkQrDialog';
import { manualRedirect } from '@/lib/redirects/inventory';
const mocks = vi.hoisted(() => ({
  api: vi.fn(),
  generate: vi.fn(),
  build: vi.fn(),
  user: 'owner',
}));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: mocks.user } }) }));
vi.mock('@/lib/redirects/memberApi', () => ({ memberRedirectApi: mocks.api }));
vi.mock('@/lib/redirects/qr', async (original) => ({
  ...(await original<typeof import('@/lib/redirects/qr')>()),
  generateQr: mocks.generate,
}));
vi.mock('@/lib/redirects/qrBundle', () => ({ buildQrBundle: mocks.build }));
let stored: {
  version: string | null;
  style: Record<string, string>;
  effectiveStyle: typeof DEFAULT_QR_STYLE;
  domainId: null;
};
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
    style: { dots: 'circle' },
    effectiveStyle: { ...DEFAULT_QR_STYLE, dots: 'circle' },
    domainId: null,
  };
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
  mocks.api.mockImplementation(async (_path, method, body) => {
    if (method === 'PATCH') {
      if (body.version !== stored.version)
        throw new Error('QR style changed; reload before saving');
      stored = {
        ...stored,
        version: 'v3',
        style: body.style ?? {},
        effectiveStyle: { ...DEFAULT_QR_STYLE, ...(body.style ?? {}) },
      };
    }
    return structuredClone(stored);
  });
});
describe('saved QR preference and export lifecycle', () => {
  it('saves shape/color overrides with the observed version and explicitly resets inheritance', async () => {
    show(<RedirectQrStyleSettings />);
    await waitFor(() => expect(screen.getByLabelText('QR dots')).toHaveValue('circle'));
    expect(screen.queryByLabelText('QR logo')).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('QR dots'), { target: { value: 'joined' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save QR style' }));
    await screen.findByText('Saved QR style.');
    expect(mocks.api).toHaveBeenCalledWith(
      '/qr-styles/workspace',
      'PATCH',
      expect.objectContaining({
        version: 'v1',
        style: expect.objectContaining({ dots: 'joined' }),
      }),
    );
    fireEvent.click(screen.getByRole('button', { name: 'Reset QR overrides' }));
    await waitFor(() => expect(screen.getByLabelText('QR dots')).toHaveValue('square'));
    expect(mocks.api).toHaveBeenLastCalledWith('/qr-styles/workspace', 'PATCH', {
      version: 'v3',
      style: null,
    });
  });
  it('retains a draft version across background refresh, surfaces conflict and reloads on request', async () => {
    const view = show(<RedirectQrStyleSettings />);
    await screen.findByLabelText('QR dots');
    fireEvent.change(screen.getByLabelText('QR dots'), { target: { value: 'joined' } });
    stored = { ...stored, version: 'v2', effectiveStyle: { ...DEFAULT_QR_STYLE, dots: 'square' } };
    await act(() => view.client.invalidateQueries({ queryKey: ['redirect-qr-preference'] }));
    expect(screen.getByLabelText('QR dots')).toHaveValue('joined');
    fireEvent.click(screen.getByRole('button', { name: 'Save QR style' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('QR style changed');
    expect(mocks.api.mock.calls.filter((call) => call[1] === 'PATCH')).toHaveLength(1);
    fireEvent.click(screen.getByRole('button', { name: 'Reload QR settings' }));
    await waitFor(() => expect(screen.getByLabelText('QR dots')).toHaveValue('square'));
  });
  it('does not reuse another account’s unsaved appearance', async () => {
    const view = show(<RedirectQrStyleSettings />);
    await screen.findByLabelText('QR dots');
    fireEvent.change(screen.getByLabelText('QR dots'), { target: { value: 'joined' } });
    mocks.user = 'second';
    stored = { ...stored, effectiveStyle: { ...DEFAULT_QR_STYLE, dots: 'square' } };
    view.rerender(
      <QueryClientProvider client={view.client}>
        <RedirectQrStyleSettings />
      </QueryClientProvider>,
    );
    await waitFor(() => expect(screen.getByLabelText('QR dots')).toHaveValue('square'));
    expect(screen.getByRole('button', { name: 'Save QR style' })).toBeDisabled();
  });
  it('blocks individual exports on preference failure until the user opts into standard appearance', async () => {
    mocks.api.mockRejectedValue(new Error('offline'));
    show(<QrExport url="https://queer.guide/go/qr-style" />);
    await screen.findByText(/Could not load saved QR style/);
    expect(mocks.generate).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Download PNG' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Use standard style for this export' }));
    await screen.findByRole('img');
    expect(mocks.generate).toHaveBeenCalledWith(
      'https://queer.guide/go/qr-style?qg_qr=1',
      DEFAULT_QR_STYLE,
      expect.objectContaining({ aborted: false }),
    );
  });
  it('blocks a missing saved logo until explicit hide and still uses the scoped saved appearance', async () => {
    mocks.api.mockResolvedValue({
      ...stored,
      effectiveLogo: { id: 'bad', url: 'https://evil.example/logo.png' },
    });
    show(<QrExport url="https://queer.guide/go/logo-failure" />);
    await screen.findByText(/Could not load saved QR style/);
    expect(mocks.generate).not.toHaveBeenCalled();
    fireEvent.click(screen.getByLabelText('Hide logos for this export'));
    await screen.findByRole('img');
    expect(mocks.generate.mock.calls.at(-1)?.[1]).toMatchObject({ dots: 'circle' });
    expect(mocks.generate.mock.calls.at(-1)?.[1].logo).toBeUndefined();
    fireEvent.click(screen.getByRole('button', { name: 'Use saved logo' }));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Download PNG' })).toBeDisabled(),
    );
  });
  it('requires explicit bulk fallback and can return from it to fresh saved styles', async () => {
    const id = '00000000-0000-4000-8000-000000000001';
    const rows = [
      manualRedirect({
        id,
        type: 'SHORT',
        slug: 'fallback-qr',
        target: '/events',
        is_enabled: true,
      }),
    ];
    mocks.api.mockRejectedValue(new Error('offline'));
    show(<RedirectBulkQrDialog rows={rows} onClose={() => {}} />);
    await screen.findByText('Could not load saved QR styles.');
    expect(screen.getByRole('button', { name: 'Prepare QR ZIP' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Use standard style for this export' }));
    fireEvent.change(screen.getByLabelText('QR dots'), { target: { value: 'circle' } });
    mocks.api.mockResolvedValue({
      data: [{ id, style: { ...DEFAULT_QR_STYLE, dots: 'joined' }, source: 'workspace' }],
    });
    fireEvent.click(screen.getByRole('button', { name: 'Use saved appearance' }));
    await waitFor(() => expect(screen.getByLabelText('QR dots')).toHaveValue('joined'));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Prepare QR ZIP' })).toBeEnabled(),
    );
  });
  it('hides a prepared bundle when the account changes', async () => {
    const id = '00000000-0000-4000-8000-000000000001';
    const rows = [
      manualRedirect({
        id,
        type: 'SHORT',
        slug: 'account-qr',
        target: '/events',
        is_enabled: true,
      }),
    ];
    mocks.api.mockResolvedValue({ data: [{ id, style: DEFAULT_QR_STYLE, source: 'default' }] });
    const view = show(<RedirectBulkQrDialog rows={rows} onClose={() => {}} />);
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Prepare QR ZIP' })).toBeEnabled(),
    );
    fireEvent.click(screen.getByRole('button', { name: 'Prepare QR ZIP' }));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Download QR ZIP' })).toBeEnabled(),
    );
    mocks.user = 'second';
    mocks.api.mockResolvedValue({
      data: [{ id, style: { ...DEFAULT_QR_STYLE, dots: 'circle' }, source: 'workspace' }],
    });
    view.rerender(
      <QueryClientProvider client={view.client}>
        <RedirectBulkQrDialog rows={rows} onClose={() => {}} />
      </QueryClientProvider>,
    );
    await waitFor(() => expect(screen.getByLabelText('QR dots')).toHaveValue('circle'));
    expect(screen.getByRole('button', { name: 'Download QR ZIP' })).toBeDisabled();
  });
  it('loads scoped per-link styles for bulk exports and applies an explicit common override', async () => {
    const a = '00000000-0000-4000-8000-000000000001',
      b = '00000000-0000-4000-8000-000000000002';
    mocks.api.mockResolvedValue({
      data: [
        { id: a, style: { ...DEFAULT_QR_STYLE, dots: 'joined' }, source: 'domain' },
        { id: b, style: { ...DEFAULT_QR_STYLE, border: 'rounded' }, source: 'workspace' },
      ],
    });
    const rows = [a, b].map((id, i) =>
      manualRedirect({
        id,
        type: 'SHORT',
        slug: 'qr-style-' + i,
        target: '/events',
        is_enabled: true,
      }),
    );
    show(<RedirectBulkQrDialog rows={rows} onClose={() => {}} />);
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Prepare QR ZIP' })).toBeEnabled(),
    );
    fireEvent.click(screen.getByRole('button', { name: 'Prepare QR ZIP' }));
    await waitFor(() => expect(mocks.build).toHaveBeenCalledOnce());
    const options = mocks.build.mock.calls[0][3];
    expect(options.stylesById.get('redirects:' + a).dots).toBe('joined');
    expect(options.stylesById.get('redirects:' + b).border).toBe('rounded');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Prepare QR ZIP' })).toBeEnabled(),
    );
    fireEvent.change(screen.getByLabelText('QR dots'), { target: { value: 'circle' } });
    expect(screen.getByRole('button', { name: 'Download QR ZIP' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Prepare QR ZIP' }));
    await waitFor(() => expect(mocks.build).toHaveBeenCalledTimes(2));
    expect(mocks.build.mock.calls[1][2]).toBe('png');
    expect(mocks.build.mock.calls[1][1].dots).toBe('circle');
    expect(mocks.build.mock.calls[1][3].stylesById.get('redirects:' + b).dots).toBe('circle');
  });
});
