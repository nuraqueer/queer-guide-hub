import { Resvg } from '@resvg/resvg-wasm';
import { Buffer } from 'node:buffer';
import jpeg from 'jpeg-js';
import { PNG } from 'pngjs';
import decodeQr from 'jsqr';
import { previewImageInfo } from '../../supabase/functions/_shared/redirect-presentation';
import { renderQrSvg, qrStyleError, type QrStyle } from '../../src/lib/redirects/qrRender';
export type QrImageFormat = 'svg' | 'png' | 'jpg';
export class QrImageError extends Error {
  constructor(
    message: string,
    readonly status = 400,
  ) {
    super(message);
  }
}
export async function validateLogoBytes(bytes: Uint8Array, expectedMime?: string) {
  let info: ReturnType<typeof previewImageInfo>;
  try {
    info = previewImageInfo(bytes);
  } catch {
    throw new QrImageError('Use a valid PNG or JPG logo.');
  }
  if (
    bytes.length > 1500000 ||
    info.width > 1024 ||
    info.height > 1024 ||
    (expectedMime && info.mime !== expectedMime)
  )
    throw new QrImageError('Use a PNG/JPG logo up to 1.5 MB and 1024px per dimension.');
  try {
    const decoded =
      info.mime === 'image/png'
        ? await new Promise<PNG>((resolve, reject) =>
            new PNG({ checkCRC: true }).parse(Buffer.from(bytes), (error, image) =>
              error ? reject(error) : resolve(image),
            ),
          )
        : jpeg.decode(bytes, {
            useTArray: true,
            formatAsRGBA: true,
            tolerantDecoding: false,
            maxResolutionInMP: 1.05,
            maxMemoryUsageInMB: 32,
          });
    if (decoded.width !== info.width || decoded.height !== info.height)
      throw new Error('Invalid dimensions');
  } catch {
    throw new QrImageError('This logo could not be decoded.');
  }
  return info;
}
export function inlineLogo(bytes: Uint8Array, mime: string) {
  return 'data:' + mime + ';base64,' + Buffer.from(bytes).toString('base64');
}
/** No DOM or destination fetches. Each Wasm allocation is released before the next mask. */
export function renderHostedQr(
  url: string,
  style: QrStyle,
  format: QrImageFormat,
  size: number,
  signal?: AbortSignal,
) {
  const invalid = qrStyleError(style);
  if (invalid) throw new QrImageError(invalid);
  for (let mask = 0; mask < 8; mask++) {
    signal?.throwIfAborted();
    let svg: string;
    try {
      svg = renderQrSvg(url, style, mask as 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7).replace(
        'width="1024" height="1024"',
        `width="${size}" height="${size}"`,
      );
    } catch {
      throw new QrImageError('The URL is too long for this QR code.', 422);
    }
    const renderer = new Resvg(svg, { font: { loadSystemFonts: false } });
    let raster: ReturnType<typeof renderer.render> | undefined;
    try {
      raster = renderer.render();
      const pixels = new Uint8ClampedArray(raster.pixels);
      if (decodeQr(pixels, size, size)?.data !== url) continue;
      signal?.throwIfAborted();
      if (format === 'svg') return { bytes: new TextEncoder().encode(svg), mime: 'image/svg+xml' };
      if (format === 'png') return { bytes: raster.asPng().slice(), mime: 'image/png' };
      const compressed = jpeg.encode({ data: pixels, width: size, height: size }, 95).data;
      const jpg = jpeg.decode(compressed, {
        useTArray: true,
        formatAsRGBA: true,
        tolerantDecoding: false,
        maxResolutionInMP: 1.05,
        maxMemoryUsageInMB: 32,
      });
      if (decodeQr(new Uint8ClampedArray(jpg.data), size, size)?.data === url)
        return { bytes: new Uint8Array(compressed), mime: 'image/jpeg' };
    } finally {
      raster?.free();
      renderer.free();
    }
  }
  throw new QrImageError(
    'This style could not be verified. Try square markers, a larger size, or remove the logo.',
    422,
  );
}
