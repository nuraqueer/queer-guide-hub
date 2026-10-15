import QRCode from 'qrcode';

export interface QrStyle {
  dots: 'square' | 'circle' | 'joined';
  border: 'square' | 'rounded' | 'circle';
  center: 'square' | 'circle';
  foreground: string;
  background: string;
  logo?: string;
}
export const DEFAULT_QR_STYLE: QrStyle = {
  dots: 'square',
  border: 'square',
  center: 'square',
  // QR ink/paper are exported artifact colors, independent of the admin theme.
  // eslint-disable-next-line no-restricted-syntax
  foreground: '#111111',
  // eslint-disable-next-line no-restricted-syntax
  background: '#ffffff',
};
function luminance(color: string) {
  const channels = [1, 3, 5]
    .map((offset) => parseInt(color.slice(offset, offset + 2), 16) / 255)
    .map((part) => (part <= 0.04045 ? part / 12.92 : ((part + 0.055) / 1.055) ** 2.4));
  return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}
export function qrStyleError(style: QrStyle): string | null {
  if (
    !['square', 'circle', 'joined'].includes(style.dots) ||
    !['square', 'rounded', 'circle'].includes(style.border) ||
    !['square', 'circle'].includes(style.center)
  )
    return 'Choose a supported QR shape.';
  if (![style.foreground, style.background].every((color) => /^#[a-f0-9]{6}$/i.test(color)))
    return 'Choose valid QR colors.';
  const dark = luminance(style.foreground),
    light = luminance(style.background);
  if (dark >= light || (light + 0.05) / (dark + 0.05) < 4.5)
    return 'Use dark dots on a light background with stronger contrast.';
  if (
    style.logo &&
    (!/^data:image\/(png|jpeg);base64,[A-Za-z0-9+/=]+$/.test(style.logo) ||
      style.logo.length > 2_100_000)
  )
    return 'Use a PNG or JPG logo smaller than 1.5 MB.';
  return null;
}

/** Four-module quiet zone; high error correction reserves room for a small logo. */
export function renderQrSvg(
  url: string,
  style: QrStyle = DEFAULT_QR_STYLE,
  maskPattern?: 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7,
): string {
  const error = qrStyleError(style);
  if (error) throw new Error(error);
  const { modules } = QRCode.create(url, { errorCorrectionLevel: 'H', maskPattern });
  const size = modules.size,
    margin = 4,
    dimension = size + margin * 2;
  const shapes: string[] = [];
  const dark = (x: number, y: number) =>
    x >= 0 && y >= 0 && x < size && y < size && !!modules.get(y, x);
  const finder = (x: number, y: number) =>
    (x < 7 && y < 7) || (x >= size - 7 && y < 7) || (x < 7 && y >= size - 7);
  for (let y = 0; y < size; y++)
    for (let x = 0; x < size; x++) {
      if (!dark(x, y) || finder(x, y)) continue;
      const px = x + margin,
        py = y + margin;
      if (style.dots === 'square' || modules.isReserved(y, x))
        shapes.push(`<rect x="${px}" y="${py}" width="1" height="1"/>`);
      else {
        shapes.push(
          `<circle cx="${px + 0.5}" cy="${py + 0.5}" r="${style.dots === 'circle' ? 0.52 : 0.5}"/>`,
        );
        if (style.dots === 'joined') {
          if (dark(x + 1, y)) shapes.push(`<rect x="${px + 0.5}" y="${py}" width="1" height="1"/>`);
          if (dark(x, y + 1)) shapes.push(`<rect x="${px}" y="${py + 0.5}" width="1" height="1"/>`);
        }
      }
    }
  const marker = (x: number, y: number, width: number, color: string, shape: QrStyle['border']) =>
    shape === 'circle'
      ? `<circle cx="${x + width / 2}" cy="${y + width / 2}" r="${width === 3 ? (style.border === 'square' && style.dots === 'circle' ? 1.8 : 1.65) : width / 2}" fill="${color}"/>`
      : `<rect x="${x}" y="${y}" width="${width}" height="${width}" rx="${shape === 'rounded' ? width / 5 : 0}" fill="${color}"/>`;
  for (const [x, y] of [
    [margin, margin],
    [size - 7 + margin, margin],
    [margin, size - 7 + margin],
  ]) {
    shapes.push(
      marker(x, y, 7, style.foreground, style.border),
      marker(x + 1, y + 1, 5, style.background, style.border),
      marker(
        x + (style.border === 'circle' && style.center === 'square' ? 2.25 : 2),
        y + (style.border === 'circle' && style.center === 'square' ? 2.25 : 2),
        style.border === 'circle' && style.center === 'square' ? 2.5 : 3,
        style.foreground,
        style.center,
      ),
    );
  }
  if (style.logo) {
    const width = Math.max(3, Math.floor(size * 0.15)),
      offset = (dimension - width) / 2;
    shapes.push(
      `<rect x="${offset - 1}" y="${offset - 1}" width="${width + 2}" height="${width + 2}" fill="${style.background}"/>`,
      `<image href="${style.logo}" x="${offset}" y="${offset}" width="${width}" height="${width}" preserveAspectRatio="xMidYMid meet"/>`,
    );
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 ${dimension} ${dimension}"><rect width="${dimension}" height="${dimension}" fill="${style.background}"/><g fill="${style.foreground}">${shapes.join('')}</g></svg>`;
}

export function qrTrackingUrl(raw: string, managedShortLink = false) {
  const url = new URL(raw);
  if (
    managedShortLink ||
    (['queer.guide', 'www.queer.guide'].includes(url.hostname) && url.pathname.startsWith('/go/'))
  )
    url.searchParams.set('qg_qr', '1');
  return url.href;
}
