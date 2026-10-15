import sharp from 'sharp';
import { randomBytes, webcrypto } from 'node:crypto';
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest';
import {
  qrLogoInput,
  type QrAssetDb,
} from '../../../../supabase/functions/_shared/redirect-qr-assets';
import {
  qrImageLinkInput,
  storeQrImageArtwork,
} from '../../../../supabase/functions/_shared/redirect-qr-images';
const id = '00000000-0000-4000-8000-000000000001',
  image = {
    id: '00000000-0000-4000-8000-000000000002',
    version: '00000000-0000-4000-8000-000000000003',
  };
const config = { origin: 'https://fixture.supabase.co', serviceKey: 'fixture-service' };
const profile = {
  url: 'https://links.community.com/',
  tracked: true,
  style: {
    dots: 'square',
    border: 'square',
    center: 'square',
    foreground: '#111111',
    background: '#ffffff',
  },
};
let logo: Awaited<ReturnType<typeof qrLogoInput>>, png: Buffer;
beforeEach(async () => {
  vi.stubGlobal('crypto', webcrypto);
  logo = await qrLogoInput({
    version: null,
    image: (
      await sharp({ create: { width: 64, height: 64, channels: 3, background: '#652895' } })
        .png()
        .toBuffer()
    ).toString('base64'),
  });
  png = await sharp({ create: { width: 1024, height: 1024, channels: 3, background: 'white' } })
    .png()
    .toBuffer();
});
afterEach(() => vi.unstubAllGlobals());
function database() {
  return {
    rpc: vi.fn<QrAssetDb['rpc']>(async (name) => ({
      data:
        name === 'reserve_redirect_qr_image_logo'
          ? { id, key: id + '.png', profile }
          : { ...image, state: 'published' },
      error: null,
    })),
  };
}
function verified() {
  return new Response(new Uint8Array(png), {
    headers: { 'Content-Type': 'image/png', 'X-QG-QR-Verified': '1' },
  });
}
describe('custom QR image publication', () => {
  it('accepts explicit artwork without allowing contradictory/incomplete modes', () => {
    expect(qrImageLinkInput({ linkId: image.id, logo: 'cG5n' })).toMatchObject({
      logoMode: 'custom',
      logo: 'cG5n',
    });
    for (const value of [
      { linkId: image.id, logo: 'cG5n', logoMode: 'none' },
      { linkId: image.id, logo: 'cG5n', logoMode: 'inherit' },
      { linkId: image.id, logoMode: 'custom' },
      { linkId: image.id, logo: 'data:image/png;base64,cG5n' },
      { linkId: image.id, logo: '' },
    ])
      expect(() => qrImageLinkInput(value)).toThrow();
  });
  it('handles large valid raster base64 without recursive regexp overflow', async () => {
    const bytes = await sharp(randomBytes(512 * 512 * 3), {
      raw: { width: 512, height: 512, channels: 3 },
    })
      .png()
      .toBuffer();
    expect(bytes.length).toBeGreaterThan(750000);
    expect(await qrLogoInput({ version: null, image: bytes.toString('base64') })).toMatchObject({
      mime: 'image/png',
      width: 512,
      height: 512,
    });
  });
  it('authorizes/reserves, scan-verifies at the fixed site, uploads once, then finalizes the same creator/draft', async () => {
    const db = database();
    const fetcher = vi.fn<typeof fetch>(async (url) =>
      String(url) === 'https://queer.guide/api/qr'
        ? verified()
        : Response.json({ Key: 'redirect-brand-assets/' + id + '.png' }),
    );
    expect(
      (await storeQrImageArtwork(db, config, 'owner', 'principal', image, logo, fetcher)).data
        .state,
    ).toBe('published');
    expect(db.rpc).toHaveBeenNthCalledWith(
      1,
      'reserve_redirect_qr_image_logo',
      expect.objectContaining({
        p_actor: 'owner',
        p_principal: 'principal',
        p_image: image.id,
        p_version: image.version,
        p_mime: 'image/png',
        p_sha256: logo.sha256,
      }),
    );
    expect(fetcher.mock.calls[0][0]).toBe('https://queer.guide/api/qr');
    expect(fetcher.mock.calls[0][1]).toMatchObject({
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      redirect: 'error',
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      cache: 'no-store',
    });
    expect(JSON.parse(fetcher.mock.calls[0][1]!.body as string)).toMatchObject({
      url: profile.url,
      tracked: '1',
      logo: expect.stringMatching(/^data:image\/png;base64,/),
    });
    expect(fetcher.mock.calls[1][0]).toBe(
      config.origin + '/storage/v1/object/redirect-brand-assets/' + id + '.png',
    );
    expect(fetcher.mock.calls[1][1]).toMatchObject({ headers: { 'x-upsert': 'false' } });
    expect(db.rpc).toHaveBeenLastCalledWith('finish_redirect_qr_image_logo', {
      p_actor: 'owner',
      p_principal: 'principal',
      p_image: image.id,
      p_asset: id,
    });
  });
  it('does not upload or publish unverified, malformed or oversized verification responses', async () => {
    const responses = [
      () => new Response(null, { status: 503 }),
      () => new Response(null, { status: 422 }),
      () => new Response(new Uint8Array(png), { headers: { 'Content-Type': 'image/png' } }),
      () =>
        new Response('<html/>', {
          headers: { 'Content-Type': 'text/html', 'X-QG-QR-Verified': '1' },
        }),
      () =>
        new Response(new Uint8Array(1500001), {
          headers: { 'Content-Type': 'image/png', 'X-QG-QR-Verified': '1' },
        }),
    ];
    for (const response of responses) {
      const db = database();
      const fetcher = vi.fn<typeof fetch>(async () => response());
      const result = await storeQrImageArtwork(db, config, null, 'principal', image, logo, fetcher);
      expect(result.error).toBeTruthy();
      expect(fetcher).toHaveBeenCalledOnce();
      expect(db.rpc).toHaveBeenCalledOnce();
    }
  });
  it('preserves rate limits, does not retry unknown uploads, and propagates final permission/version conflicts', async () => {
    const db = database();
    const limited = await storeQrImageArtwork(
      db,
      config,
      null,
      'principal',
      image,
      logo,
      async () => new Response(null, { status: 429 }),
    );
    expect(limited.data.retryAfter).toBe(60);
    expect(db.rpc).toHaveBeenCalledOnce();
    const unknown = database();
    const fetcher = vi.fn<typeof fetch>(async (url) => {
      if (String(url) === 'https://queer.guide/api/qr') return verified();
      throw new Error('lost upload receipt');
    });
    expect(
      (await storeQrImageArtwork(unknown, config, null, 'principal', image, logo, fetcher)).error
        ?.code,
    ).toBe('QR_STORAGE');
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(unknown.rpc).toHaveBeenCalledOnce();
    const stale = database();
    stale.rpc.mockImplementation(async (name) =>
      name === 'reserve_redirect_qr_image_logo'
        ? { data: { id, key: id + '.png', profile }, error: null }
        : { data: null, error: { code: '23505', message: 'Draft changed' } },
    );
    expect(
      (
        await storeQrImageArtwork(stale, config, null, 'principal', image, logo, async (url) =>
          String(url) === 'https://queer.guide/api/qr'
            ? verified()
            : Response.json({ Key: 'redirect-brand-assets/' + id + '.png' }),
        )
      ).error?.code,
    ).toBe('23505');
  });
});
