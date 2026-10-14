import { UUID, tokenDigest } from './redirect-api.ts';
import { qrStylePreferenceInput } from './redirect-qr-style.ts';
import { qrLogoPublicResponse, type QrAssetDb } from './redirect-qr-assets.ts';
export const QR_IMAGE_TOKEN = /^qg_qr_[a-f0-9]{64}$/;
export function createQrImageToken() {
  return (
    'qg_qr_' +
    Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) =>
      byte.toString(16).padStart(2, '0'),
    ).join('')
  );
}
export function qrImageLinkInput(value: unknown) {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new Error('Provide image link fields');
  const data = value as Record<string, unknown>;
  if (
    Object.keys(data).some(
      (key) => !['linkId', 'url', 'label', 'expiresAt', 'style', 'logoMode'].includes(key),
    ) ||
    Object.hasOwn(data, 'linkId') === Object.hasOwn(data, 'url')
  )
    throw new Error('Choose a link or an explicit URL');
  const result: Record<string, unknown> = {};
  if ('linkId' in data) {
    if (typeof data.linkId !== 'string' || !UUID.test(data.linkId))
      throw new Error('Choose a valid managed link');
    result.linkId = data.linkId;
  } else {
    if (
      typeof data.url !== 'string' ||
      /\s/.test(data.url) ||
      Array.from(data.url).some((char) => char.charCodeAt(0) < 32)
    )
      throw new Error('Provide an HTTP(S) URL without credentials');
    let url: URL;
    try {
      url = new URL(data.url);
    } catch {
      throw new Error('Provide a valid HTTP(S) URL');
    }
    if (
      !['http:', 'https:'].includes(url.protocol) ||
      url.username ||
      url.password ||
      new TextEncoder().encode(url.href).length > 2048
    )
      throw new Error('Provide an HTTP(S) URL without credentials up to 2048 bytes');
    result.url = url.href;
  }
  if ('label' in data) {
    if (typeof data.label !== 'string' || !data.label.trim() || data.label.trim().length > 100)
      throw new Error('Image label must be 1–100 characters');
    result.label = data.label.trim();
  }
  if ('expiresAt' in data) {
    if (data.expiresAt === null) result.expiresAt = null;
    else {
      if (
        typeof data.expiresAt !== 'string' ||
        !Number.isFinite(Date.parse(data.expiresAt)) ||
        Date.parse(data.expiresAt) <= Date.now() ||
        Date.parse(data.expiresAt) > Date.now() + 366 * 86400000
      )
        throw new Error('Choose expiry within one year or no expiry');
      result.expiresAt = new Date(data.expiresAt).toISOString();
    }
  }
  if ('style' in data)
    result.style = (
      qrStylePreferenceInput({ version: null, style: data.style }) as { style: unknown }
    ).style;
  if ('logoMode' in data) {
    if (!['inherit', 'none'].includes(data.logoMode as string))
      throw new Error('Choose inherited or hidden artwork');
    result.logoMode = data.logoMode;
  }
  return result;
}
export function qrImageRevokeInput(value: unknown) {
  if (
    !value ||
    typeof value !== 'object' ||
    Array.isArray(value) ||
    Object.keys(value).length !== 1 ||
    typeof (value as Record<string, unknown>).version !== 'string' ||
    !UUID.test((value as Record<string, string>).version)
  )
    throw new Error('Provide the current image version');
  return { version: (value as Record<string, string>).version };
}
export function qrImageUrls(token: string) {
  if (!QR_IMAGE_TOKEN.test(token)) throw new Error('Invalid image capability');
  const url = (format: string) =>
    'https://queer.guide/api/qr?' + new URLSearchParams({ share: token, format });
  return { png: url('png'), jpg: url('jpg'), svg: url('svg') };
}
export async function publicQrImageRequest(
  req: Request,
  db: QrAssetDb,
  storageOrigin: string,
  cors: Record<string, string> = {},
) {
  const headers = {
    ...cors,
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer',
    'X-Robots-Tag': 'noindex',
    'X-Content-Type-Options': 'nosniff',
  };
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers });
  if (req.method !== 'GET' || new URL(req.url).search)
    return json({ error: 'Invalid public QR image request' }, 400);
  const token = req.headers.get('Authorization')?.match(/^Bearer (qg_qr_[a-f0-9]{64})$/)?.[1];
  if (!token) return json({ error: 'QR image link not found' }, 404);
  try {
    const result = await db.rpc('redirect_public_qr_image', { p_hash: await tokenDigest(token) });
    if (result.error)
      return json(
        {
          error: result.error.code?.startsWith('22')
            ? 'Saved QR branding is unavailable; review its settings'
            : 'QR image profile unavailable',
        },
        result.error.code?.startsWith('22') ? 422 : 503,
      );
    if (!result.data) return json({ error: 'QR image link not found' }, 404);
    return json(qrLogoPublicResponse(result.data, storageOrigin));
  } catch {
    return json({ error: 'QR image profile unavailable' }, 503);
  }
}
