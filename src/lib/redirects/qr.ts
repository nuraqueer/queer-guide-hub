import { renderQrSvg, type QrStyle } from './qrRender';
export {
  DEFAULT_QR_STYLE,
  qrStyleError,
  renderQrSvg,
  qrTrackingUrl,
  type QrStyle,
} from './qrRender';

async function qrCanvas(svg: string) {
  const image = new Image();
  image.src = svg.startsWith('data:')
    ? svg
    : 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  await image.decode();
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 1024;
  const context = canvas.getContext('2d');
  if (!context) throw new Error('Image export is unavailable in this browser.');
  context.drawImage(image, 0, 0, 1024, 1024);
  return { canvas, context };
}

/** Try the eight standard masks and verify the actual raster before offering exports. */
export async function generateQr(url: string, style: QrStyle, signal?: AbortSignal) {
  signal?.throwIfAborted();
  const { default: decode } = await import('jsqr');
  for (let mask = 0; mask < 8; mask++) {
    signal?.throwIfAborted();
    const svg = renderQrSvg(url, style, mask as 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7);
    const { canvas, context } = await qrCanvas(svg);
    signal?.throwIfAborted();
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height);
    if (decode(pixels.data, pixels.width, pixels.height)?.data === url) {
      const jpg = canvas.toDataURL('image/jpeg', 0.95);
      const compressed = await qrCanvas(jpg);
      const jpgPixels = compressed.context.getImageData(0, 0, canvas.width, canvas.height);
      signal?.throwIfAborted();
      if (decode(jpgPixels.data, jpgPixels.width, jpgPixels.height)?.data === url)
        return { svg, png: canvas.toDataURL('image/png'), jpg };
    }
  }
  throw new Error('This style could not be verified. Try square markers or remove the logo.');
}
