import sharp from 'sharp';
import { webcrypto } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  qrLogoInput,
  qrLogoPublicResponse,
  qrAssetStorageConfig,
  storeRedirectQrLogo,
  dispatchRedirectQrAssetCleanup,
  type QrAssetDb,
} from '../../../../supabase/functions/_shared/redirect-qr-assets';
const actor = '00000000-0000-4000-8000-000000000001',
  id = '00000000-0000-4000-8000-000000000002',
  lease = '00000000-0000-4000-8000-000000000003';
const config = { origin: 'https://fixture.supabase.co', serviceKey: 'fixture-service' };
beforeEach(() => vi.stubGlobal('crypto', webcrypto));
afterEach(() => vi.unstubAllGlobals());
async function image(format: 'png' | 'jpeg' = 'png', width = 64) {
  const bytes = await sharp({ create: { width, height: 64, channels: 3, background: '#221144' } })
    [format]()
    .toBuffer();
  return { version: null, image: bytes.toString('base64') };
}
function database() {
  return {
    rpc: vi.fn<QrAssetDb['rpc']>(async (name) => ({
      data:
        name === 'reserve_redirect_qr_logo'
          ? { id, key: id + '.png' }
          : name === 'claim_redirect_qr_asset_cleanup'
            ? [{ id, lease, key: id + '.png' }]
            : true,
      error: null,
    })),
  };
}
describe('controlled QR logo storage transport', () => {
  it('derives hosted URLs from the fixed public bucket and refuses arbitrary hosts or object paths', () => {
    const value = { effectiveLogo: { id, key: id + '.png' }, logoAsset: null };
    expect(qrLogoPublicResponse(value, config.origin).effectiveLogo.url).toBe(
      config.origin + '/storage/v1/object/public/redirect-brand-assets/' + id + '.png',
    );
    expect(() => qrLogoPublicResponse(value, 'https://evil.example')).toThrow('Invalid hosted');
    expect(() =>
      qrLogoPublicResponse({ effectiveLogo: { id, key: '../private' } }, config.origin),
    ).toThrow('Invalid hosted');
  });
  it('derives raster type/dimensions/digest and refuses SVG, oversized dimensions and caller metadata', async () => {
    const png = await qrLogoInput(await image());
    expect(png).toMatchObject({
      mime: 'image/png',
      width: 64,
      height: 64,
      extension: 'png',
      sha256: expect.stringMatching(/^[a-f0-9]{64}$/),
    });
    expect((await qrLogoInput(await image('jpeg'))).mime).toBe('image/jpeg');
    for (const input of [
      { version: null, image: btoa('<svg onload="alert(1)"/>') },
      await image('png', 1025),
      { ...(await image()), mime: 'image/png' },
      { version: 'stale', image: 'aaaa' },
      { version: null, image: 'bad base64' },
    ])
      await expect(qrLogoInput(input)).rejects.toThrow();
  });
  it('binds no-overwrite upload to the reserved key and only finalizes after a matching receipt', async () => {
    const db = database();
    const fetcher = vi.fn<typeof fetch>(async () =>
      Response.json({ Key: 'redirect-brand-assets/' + id + '.png' }),
    );
    const input = await qrLogoInput(await image());
    await storeRedirectQrLogo(db, config, actor, null, input, fetcher);
    expect(fetcher).toHaveBeenCalledWith(
      config.origin + '/storage/v1/object/redirect-brand-assets/' + id + '.png',
      expect.objectContaining({
        method: 'POST',
        redirect: 'error',
        cache: 'no-store',
        headers: expect.objectContaining({ 'x-upsert': 'false', 'Content-Type': 'image/png' }),
      }),
    );
    expect(db.rpc).toHaveBeenLastCalledWith('finish_redirect_qr_logo', {
      p_actor: actor,
      p_id: id,
    });
    expect(db.rpc.mock.calls[0][1]).toMatchObject({
      p_sha256: input.sha256,
      p_mime: 'image/png',
      p_width: 64,
      p_bytes: input.bytes.length,
    });
  });
  it('does not retry uncertain writes or finalize mismatched/redirecting receipts', async () => {
    for (const fetcher of [
      vi.fn<typeof fetch>(async () => {
        throw new Error('lost response');
      }),
      vi.fn<typeof fetch>(async () => Response.json({ Key: 'other.png' })),
      vi.fn<typeof fetch>(
        async () =>
          new Response(null, { status: 302, headers: { Location: 'https://evil.example' } }),
      ),
    ]) {
      const db = database();
      const result = await storeRedirectQrLogo(
        db,
        config,
        actor,
        null,
        await qrLogoInput(await image()),
        fetcher,
      );
      expect(result.error?.code).toBe('QR_STORAGE');
      expect(fetcher).toHaveBeenCalledTimes(1);
      expect(db.rpc.mock.calls.some(([name]) => name === 'finish_redirect_qr_logo')).toBe(false);
    }
  });
  it('does not send bytes for rejected reservations and only accepts the fixed project origin', async () => {
    const db = database();
    db.rpc.mockResolvedValue({ data: null, error: { code: '23505', message: 'stale' } });
    const fetcher = vi.fn<typeof fetch>();
    await storeRedirectQrLogo(db, config, actor, null, await qrLogoInput(await image()), fetcher);
    expect(fetcher).not.toHaveBeenCalled();
    expect(qrAssetStorageConfig('http://fixture.supabase.co', 'key')).toBeNull();
    expect(qrAssetStorageConfig('https://evil.example', 'key')).toBeNull();
    expect(qrAssetStorageConfig('https://fixture.supabase.co/', 'fixture-service')).toEqual(config);
  });
  it('deletes only the leased key through Storage and records failures for durable retry', async () => {
    const db = database();
    const fetcher = vi.fn<typeof fetch>(async () => Response.json([{ name: id + '.png' }]));
    expect(await dispatchRedirectQrAssetCleanup(db, config, fetcher)).toMatchObject({
      processed: 1,
      failed: 0,
    });
    expect(JSON.parse(fetcher.mock.calls[0][1]!.body as string)).toEqual({
      prefixes: [id + '.png'],
    });
    expect(db.rpc).toHaveBeenLastCalledWith('finish_redirect_qr_asset_cleanup', {
      p_id: id,
      p_lease: lease,
      p_success: true,
    });
    fetcher.mockRejectedValue(new Error('offline'));
    expect(await dispatchRedirectQrAssetCleanup(db, config, fetcher)).toMatchObject({
      processed: 1,
      failed: 1,
    });
    expect(db.rpc).toHaveBeenLastCalledWith('finish_redirect_qr_asset_cleanup', {
      p_id: id,
      p_lease: lease,
      p_success: false,
    });
  });
  it('does not claim while unconfigured and refuses arbitrary paths in cleanup work', async () => {
    const db = database();
    const fetcher = vi.fn<typeof fetch>();
    expect(await dispatchRedirectQrAssetCleanup(db, null, fetcher)).toMatchObject({
      configured: false,
    });
    expect(db.rpc).not.toHaveBeenCalled();
    db.rpc.mockResolvedValue({ data: [{ id, lease, key: '../private' }], error: null });
    await expect(dispatchRedirectQrAssetCleanup(db, config, fetcher)).rejects.toThrow(
      'Invalid asset',
    );
    expect(fetcher).not.toHaveBeenCalled();
  });
});
