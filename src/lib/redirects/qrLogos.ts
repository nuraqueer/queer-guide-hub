import { supabase } from '@/integrations/supabase/client';
import { previewImageInfo } from '../../../supabase/functions/_shared/redirect-presentation';
import type { QrStyle } from './qr';
export interface QrLogoAsset {
  id: string;
  key: string;
  url: string;
  mime: 'image/png' | 'image/jpeg';
  bytes: number;
  width: number;
  height: number;
  sha256: string;
}
export type LoadedQrStyle = QrStyle & { logoIdentity?: string };
export const MAX_SAVED_LOGO_BYTES = 1500000;
export const MAX_BULK_LOGO_BYTES = 16000000;
export function qrAppearance(style: QrStyle): Omit<QrStyle, 'logo'> {
  return {
    dots: style.dots,
    border: style.border,
    center: style.center,
    foreground: style.foreground,
    background: style.background,
  };
}
export function validateQrLogoAsset(asset: QrLogoAsset) {
  if (
    !asset ||
    !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(asset.id) ||
    !['image/png', 'image/jpeg'].includes(asset.mime) ||
    asset.key !== asset.id + (asset.mime === 'image/png' ? '.png' : '.jpg') ||
    !Number.isInteger(asset.bytes) ||
    asset.bytes < 1 ||
    asset.bytes > MAX_SAVED_LOGO_BYTES ||
    ![asset.width, asset.height].every((n) => Number.isInteger(n) && n > 0 && n <= 1024) ||
    !/^[a-f0-9]{64}$/.test(asset.sha256)
  )
    throw new Error('Invalid saved logo metadata');
  const expected = supabase.storage.from('redirect-brand-assets').getPublicUrl(asset.key)
    .data.publicUrl;
  const url = new URL(expected);
  if (
    url.protocol !== 'https:' ||
    url.username ||
    url.password ||
    url.port ||
    url.search ||
    url.hash ||
    asset.url !== expected
  )
    throw new Error('Invalid saved logo URL');
  return expected;
}
function logoDataUrl(bytes: Uint8Array, mime: string) {
  let text = '';
  for (let i = 0; i < bytes.length; i += 8192)
    text += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return 'data:' + mime + ';base64,' + btoa(text);
}
async function decodeLogo(data: string, width: number, height: number, signal?: AbortSignal) {
  signal?.throwIfAborted();
  const image = new Image();
  image.src = data;
  await new Promise<void>((resolve, reject) => {
    let finished = false;
    const complete = (error?: unknown) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      if (error) {
        image.src = '';
        reject(error);
      } else resolve();
    };
    const abort = () => complete(signal?.reason ?? new DOMException('Aborted', 'AbortError'));
    const timer = setTimeout(() => complete(new Error('Logo decode timed out')), 8000);
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) {
      abort();
      return;
    }
    Promise.resolve()
      .then(() => image.decode())
      .then(
        () =>
          complete(
            (image.naturalWidth === width && image.naturalHeight === height) ||
              (image.naturalWidth === height && image.naturalHeight === width)
              ? undefined
              : new Error('Saved logo dimensions changed'),
          ),
        complete,
      );
  });
  signal?.throwIfAborted();
}
export async function loadQrLogo(
  asset: QrLogoAsset,
  signal?: AbortSignal,
  fetcher: typeof fetch = fetch,
) {
  signal = signal
    ? AbortSignal.any([signal, AbortSignal.timeout(15000)])
    : AbortSignal.timeout(15000);
  const url = validateQrLogoAsset(asset);
  signal?.throwIfAborted();
  const response = await fetcher(url, {
    method: 'GET',
    credentials: 'omit',
    referrerPolicy: 'no-referrer',
    redirect: 'error',
    cache: 'no-store',
    signal,
  });
  if (
    !response.ok ||
    !response.body ||
    response.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase() !== asset.mime
  ) {
    await response.body?.cancel();
    throw new Error('Saved logo could not be loaded');
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      signal?.throwIfAborted();
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > asset.bytes || size > MAX_SAVED_LOGO_BYTES)
        throw new Error('Saved logo size changed');
      chunks.push(value);
    }
  } catch (error) {
    await reader.cancel();
    throw error;
  }
  if (size !== asset.bytes) throw new Error('Saved logo size changed');
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of chunks) {
    bytes.set(part, offset);
    offset += part.length;
  }
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  if (Array.from(digest, (n) => n.toString(16).padStart(2, '0')).join('') !== asset.sha256)
    throw new Error('Saved logo integrity check failed');
  const info = previewImageInfo(bytes);
  if (info.mime !== asset.mime || info.width !== asset.width || info.height !== asset.height)
    throw new Error('Saved logo dimensions changed');
  const data = logoDataUrl(bytes, asset.mime);
  await decodeLogo(data, asset.width, asset.height, signal);
  return data;
}
export async function hydrateQrStyles<
  T extends { id: string; style: QrStyle; effectiveLogo?: QrLogoAsset | null },
>(
  rows: T[],
  signal?: AbortSignal,
  skipLogos = false,
  fetcher: typeof fetch = fetch,
): Promise<Array<Omit<T, 'style'> & { style: LoadedQrStyle }>> {
  if (skipLogos) return rows.map((row) => ({ ...row, style: qrAppearance(row.style) }));
  const assets = new Map<string, QrLogoAsset>();
  for (const row of rows)
    if (row.effectiveLogo) {
      const asset = row.effectiveLogo;
      validateQrLogoAsset(asset);
      const previous = assets.get(asset.id);
      if (previous && JSON.stringify(previous) !== JSON.stringify(asset))
        throw new Error('Saved logo metadata changed');
      assets.set(asset.id, asset);
    }
  if ([...assets.values()].reduce((sum, asset) => sum + asset.bytes, 0) > MAX_BULK_LOGO_BYTES)
    throw new Error('Saved logos exceed 16 MB. Select fewer links or hide logos for this export.');
  const controller = new AbortController();
  const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
  const list = [...assets.values()];
  let index = 0;
  const loaded = new Map<string, string>();
  try {
    await Promise.all(
      Array.from({ length: Math.min(3, list.length) }, async () => {
        while (index < list.length) {
          combined.throwIfAborted();
          const asset = list[index++];
          loaded.set(asset.id, await loadQrLogo(asset, combined, fetcher));
        }
      }),
    );
  } catch (error) {
    controller.abort(error);
    throw error;
  }
  signal?.throwIfAborted();
  return rows.map((row) => ({
    ...row,
    style: {
      ...qrAppearance(row.style),
      ...(row.effectiveLogo
        ? {
            logo: loaded.get(row.effectiveLogo.id),
            logoIdentity: row.effectiveLogo.id + ':' + row.effectiveLogo.sha256,
          }
        : {}),
    },
  }));
}
export async function readQrLogoFile(file: File) {
  if (!file.size || file.size > MAX_SAVED_LOGO_BYTES)
    throw new Error('Use a PNG/JPG logo no larger than 1.5 MB and 1024px per dimension.');
  const data = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(new Error('Could not read this logo'));
    reader.readAsDataURL(file);
  });
  const image = data.split(',')[1];
  const bytes = Uint8Array.from(atob(image), (char) => char.charCodeAt(0));
  const info = previewImageInfo(bytes);
  if (info.width > 1024 || info.height > 1024)
    throw new Error('Logo dimensions must be no larger than 1024 × 1024');
  const normalized = logoDataUrl(bytes, info.mime);
  await decodeLogo(normalized, info.width, info.height);
  return { data: normalized, image };
}
