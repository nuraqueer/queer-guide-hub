import sharp from 'sharp';
import { webcrypto } from 'node:crypto';
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest';
import { hydrateQrStyles, loadQrLogo, readQrLogoFile, type QrLogoAsset } from '../qrLogos';
import { DEFAULT_QR_STYLE } from '../qr';
vi.mock('@/integrations/supabase/client', () => ({
  supabase: {
    storage: {
      from: () => ({
        getPublicUrl: (key: string) => ({
          data: {
            publicUrl:
              'https://fixture.supabase.co/storage/v1/object/public/redirect-brand-assets/' + key,
          },
        }),
      }),
    },
  },
}));
class DecodedImage {
  src = '';
  naturalWidth = 0;
  naturalHeight = 0;
  async decode() {
    const info = await sharp(Buffer.from(this.src.split(',')[1], 'base64')).metadata();
    this.naturalWidth = info.width!;
    this.naturalHeight = info.height!;
  }
}
beforeEach(() => {
  vi.stubGlobal('crypto', webcrypto);
  vi.stubGlobal('Image', DecodedImage);
});
afterEach(() => vi.unstubAllGlobals());
async function fixture(index = 1, mime: 'image/png' | 'image/jpeg' = 'image/png') {
  const bytes = await sharp({
    create: { width: 64, height: 48, channels: 3, background: '#221144' },
  })
    [mime === 'image/png' ? 'png' : 'jpeg']()
    .toBuffer();
  const id = '00000000-0000-4000-8000-' + String(index).padStart(12, '0');
  const key = id + (mime === 'image/png' ? '.png' : '.jpg');
  const asset: QrLogoAsset = {
    id,
    key,
    url: 'https://fixture.supabase.co/storage/v1/object/public/redirect-brand-assets/' + key,
    mime,
    width: 64,
    height: 48,
    bytes: bytes.length,
    sha256: Buffer.from(await webcrypto.subtle.digest('SHA-256', bytes)).toString('hex'),
  };
  return {
    bytes,
    asset,
    response: () => new Response(bytes, { headers: { 'Content-Type': mime } }),
  };
}
describe('verified saved QR logos', () => {
  it('limits parallel transfers to three and cancels siblings after a failure', async () => {
    const fixtures = await Promise.all([1, 2, 3, 4, 5, 6].map((index) => fixture(index)));
    let active = 0,
      maximum = 0;
    const releases: (() => void)[] = [];
    const fetcher = vi.fn<typeof fetch>(
      (url) =>
        new Promise((resolve) => {
          maximum = Math.max(maximum, ++active);
          releases.push(() => {
            active--;
            resolve(fixtures.find((item) => item.asset.url === url)!.response());
          });
        }),
    );
    const rows = fixtures.map((item) => ({
      id: item.asset.id,
      style: DEFAULT_QR_STYLE,
      effectiveLogo: item.asset,
    }));
    const pending = hydrateQrStyles(rows, undefined, false, fetcher);
    expect(fetcher).toHaveBeenCalledTimes(3);
    releases.splice(0).forEach((release) => release());
    await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(6));
    releases.splice(0).forEach((release) => release());
    await pending;
    expect(maximum).toBe(3);
    const aborted = vi.fn();
    const failing = vi.fn<typeof fetch>(async (_url, init) => {
      if (failing.mock.calls.length === 1) throw new Error('missing saved logo');
      return new Promise((_resolve, reject) =>
        init!.signal!.addEventListener(
          'abort',
          () => {
            aborted();
            reject(init!.signal!.reason);
          },
          { once: true },
        ),
      );
    });
    await expect(hydrateQrStyles(rows, undefined, false, failing)).rejects.toThrow(
      'missing saved logo',
    );
    expect(aborted).toHaveBeenCalledTimes(2);
  });
  it.each(['image/png', 'image/jpeg'] as const)(
    'loads exact %s bytes from the configured public bucket',
    async (mime) => {
      const { asset, bytes, response } = await fixture(1, mime);
      const fetcher = vi.fn<typeof fetch>(async () => response());
      expect(await loadQrLogo(asset, undefined, fetcher)).toBe(
        'data:' + mime + ';base64,' + bytes.toString('base64'),
      );
      expect(fetcher).toHaveBeenCalledWith(
        asset.url,
        expect.objectContaining({
          credentials: 'omit',
          redirect: 'error',
          referrerPolicy: 'no-referrer',
          cache: 'no-store',
        }),
      );
    },
  );
  it('rejects arbitrary hosts, paths, invalid metadata and mismatched digests', async () => {
    const { asset, response } = await fixture();
    const fetcher = vi.fn<typeof fetch>(async () => response());
    for (const change of [
      { url: 'https://evil.example/logo.png' },
      { key: '../private' },
      { id: '-'.repeat(36) },
      { width: 1025 },
      { bytes: 1500001 },
    ])
      await expect(loadQrLogo({ ...asset, ...change }, undefined, fetcher)).rejects.toThrow();
    expect(fetcher).not.toHaveBeenCalled();
    await expect(
      loadQrLogo({ ...asset, sha256: 'a'.repeat(64) }, undefined, fetcher),
    ).rejects.toThrow('integrity');
  });
  it('rejects response MIME, size, header dimensions and raster decoding changes', async () => {
    const { asset, bytes } = await fixture();
    await expect(
      loadQrLogo(
        asset,
        undefined,
        async () => new Response(bytes, { headers: { 'Content-Type': 'text/html' } }),
      ),
    ).rejects.toThrow('could not be loaded');
    await expect(
      loadQrLogo(
        { ...asset, bytes: bytes.length - 1 },
        undefined,
        async () => new Response(bytes, { headers: { 'Content-Type': asset.mime } }),
      ),
    ).rejects.toThrow('size');
    await expect(
      loadQrLogo(
        { ...asset, width: 63 },
        undefined,
        async () => new Response(bytes, { headers: { 'Content-Type': asset.mime } }),
      ),
    ).rejects.toThrow('dimensions');
    vi.stubGlobal(
      'Image',
      class extends DecodedImage {
        async decode() {
          throw new Error('decode failed');
        }
      },
    );
    await expect(
      loadQrLogo(
        asset,
        undefined,
        async () => new Response(bytes, { headers: { 'Content-Type': asset.mime } }),
      ),
    ).rejects.toThrow('decode failed');
  });
  it('deduplicates shared assets and keeps each row’s logo identity', async () => {
    const a = await fixture(1),
      b = await fixture(2, 'image/jpeg');
    const fetcher = vi.fn<typeof fetch>(async (url) =>
      url === a.asset.url ? a.response() : b.response(),
    );
    const rows = await hydrateQrStyles(
      [a, a, b].map((item, i) => ({
        id: String(i),
        style: DEFAULT_QR_STYLE,
        effectiveLogo: item.asset,
      })),
      undefined,
      false,
      fetcher,
    );
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(rows[0].style.logo).toBe(rows[1].style.logo);
    expect(rows[2].style.logoIdentity).not.toBe(rows[0].style.logoIdentity);
    expect(rows[2].style.logo).toContain('data:image/jpeg;');
  });
  it('caps aggregate transfers before fetching and permits explicit logo-free recovery', async () => {
    const { asset } = await fixture();
    const fetcher = vi.fn<typeof fetch>();
    const rows = Array.from({ length: 11 }, (_, i) => {
      const id = asset.id.slice(0, -2) + String(i).padStart(2, '0');
      const key = id + '.png';
      return {
        id,
        style: DEFAULT_QR_STYLE,
        effectiveLogo: {
          ...asset,
          id,
          key,
          url: asset.url.replace(asset.key, key),
          bytes: 1500000,
        },
      };
    });
    await expect(hydrateQrStyles(rows, undefined, false, fetcher)).rejects.toThrow('16 MB');
    expect(await hydrateQrStyles(rows, undefined, true, fetcher)).toHaveLength(11);
    expect(fetcher).not.toHaveBeenCalled();
  });
  it('cancels obsolete reads and reads local files using their bytes rather than the claimed MIME', async () => {
    const { asset, bytes } = await fixture();
    const controller = new AbortController();
    controller.abort();
    const fetcher = vi.fn<typeof fetch>();
    await expect(loadQrLogo(asset, controller.signal, fetcher)).rejects.toThrow();
    expect(fetcher).not.toHaveBeenCalled();
    expect(
      await readQrLogoFile(new File([bytes], 'logo.jpg', { type: 'image/jpeg' })),
    ).toMatchObject({ data: 'data:image/png;base64,' + bytes.toString('base64') });
    await expect(
      readQrLogoFile(new File(['<svg/>'], 'logo.png', { type: 'image/png' })),
    ).rejects.toThrow();
  });
});
