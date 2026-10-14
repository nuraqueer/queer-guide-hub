import { UUID } from './redirect-api.ts';
import {
  qrLogoInput,
  uploadQrLogoObject,
  type QrAssetDb,
  type QrAssetStorage,
} from './redirect-qr-assets.ts';
export function passwordBrandingInput(input: unknown) {
  if (!input || typeof input !== 'object' || Array.isArray(input))
    throw new Error('Provide password branding changes');
  const value = input as Record<string, unknown>;
  if (
    Object.keys(value).some((key) => !['version', 'brandName', 'clearLogo'].includes(key)) ||
    !Object.hasOwn(value, 'version') ||
    (value.version !== null && (typeof value.version !== 'string' || !UUID.test(value.version))) ||
    Object.keys(value).length < 2
  )
    throw new Error('Provide the current branding version and changes');
  if (
    Object.hasOwn(value, 'brandName') &&
    value.brandName !== null &&
    (typeof value.brandName !== 'string' ||
      value.brandName.trim().length > 80 ||
      /[\x00-\x1f\x7f]/.test(value.brandName))
  )
    throw new Error('Brand name must be plain text up to 80 characters');
  if (Object.hasOwn(value, 'clearLogo') && typeof value.clearLogo !== 'boolean')
    throw new Error('Invalid logo removal');
  return {
    ...value,
    ...(typeof value.brandName === 'string' ? { brandName: value.brandName.trim() || null } : {}),
  };
}
export async function storePasswordLogo(
  db: QrAssetDb,
  config: QrAssetStorage,
  actor: string | null,
  principal: string | null,
  link: string,
  input: Awaited<ReturnType<typeof qrLogoInput>>,
  fetcher: typeof fetch = fetch,
) {
  const reserved = await db.rpc('reserve_redirect_password_logo', {
    p_actor: actor,
    p_principal: principal,
    p_link: link,
    p_version: input.version,
    p_mime: input.mime,
    p_bytes: input.bytes.length,
    p_width: input.width,
    p_height: input.height,
    p_sha256: input.sha256,
  });
  if (reserved.error || reserved.data?.retryAfter) return reserved;
  const asset = reserved.data;
  if (!asset || !UUID.test(asset.id) || asset.key !== asset.id + '.' + input.extension)
    throw new Error('Invalid password-logo reservation');
  try {
    await uploadQrLogoObject(config, asset, input, fetcher);
  } catch {
    return {
      data: null,
      error: {
        code: 'QR_STORAGE',
        message:
          'Password logo upload receipt is unavailable. Reload branding before trying again; the reserved asset will be cleaned up.',
      },
    };
  }
  return db.rpc('finish_redirect_password_logo', {
    p_actor: actor,
    p_principal: principal,
    p_link: link,
    p_id: asset.id,
  });
}
