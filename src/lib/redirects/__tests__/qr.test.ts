import sharp from 'sharp';
import jsQR from 'jsqr';
import { describe, expect, it } from 'vitest';
import { DEFAULT_QR_STYLE, qrTrackingUrl, qrStyleError, renderQrSvg, type QrStyle } from '../qr';

const link = 'https://queer.guide/go/pride-qr?utm_source=poster#details';
async function decode(svg: string, jpg = false) {
  const image = jpg
    ? sharp(await sharp(Buffer.from(svg)).jpeg({ quality: 95 }).toBuffer())
    : sharp(Buffer.from(svg));
  const { data, info } = await image.ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  return jsQR(new Uint8ClampedArray(data), info.width, info.height)?.data;
}
describe('branded QR scanability', () => {
  for (const dots of ['square', 'circle', 'joined'] as const) {
    for (const border of ['square', 'rounded', 'circle'] as const) {
      for (const center of ['square', 'circle'] as const) {
        it(`decodes ${dots} dots / ${border} border / ${center} center`, async () => {
          let result: string | undefined;
          for (let mask = 0; mask < 8 && !result; mask++) {
            const svg = renderQrSvg(
              link,
              {
                ...DEFAULT_QR_STYLE,
                dots,
                border,
                center,
                foreground: '#163b56',
                background: '#fff9eb',
              },
              mask as 0,
            );
            if ((await decode(svg)) === link && (await decode(svg, true)) === link) result = link;
          }
          expect(result).toBe(link);
        });
      }
    }
  }
  it('decodes an image-bearing code and a short URL with the logo quiet space', async () => {
    const png = await sharp({
      create: { width: 64, height: 64, channels: 4, background: '#af185a' },
    })
      .png()
      .toBuffer();
    const style: QrStyle = {
      ...DEFAULT_QR_STYLE,
      logo: 'data:image/png;base64,' + png.toString('base64'),
    };
    for (const url of [link, 'https://queer.guide/go/abc'])
      expect(await decode(renderQrSvg(url, style))).toBe(url);
  });
  it('annotates known managed branded QR links and leaves ordinary external URLs alone', async () => {
    const raw = 'https://links.community.com/pride-qr?utm_source=poster';
    expect(qrTrackingUrl(raw)).toBe(raw);
    const tracked = qrTrackingUrl(raw, true);
    expect(new URL(tracked).searchParams.get('qg_qr')).toBe('1');
    expect(await decode(renderQrSvg(tracked))).toBe(tracked);
  });
  it('blocks low contrast, inverted colors and unsafe logo markup', () => {
    expect(qrStyleError({ ...DEFAULT_QR_STYLE, foreground: '#eeeeee' })).toContain('contrast');
    expect(
      qrStyleError({ ...DEFAULT_QR_STYLE, foreground: '#ffffff', background: '#000000' }),
    ).toContain('dark dots');
    expect(() =>
      renderQrSvg(link, { ...DEFAULT_QR_STYLE, foreground: 'red" onload="alert(1)' }),
    ).toThrow('valid QR colors');
    expect(qrStyleError({ ...DEFAULT_QR_STYLE, logo: 'https://example.com/logo.svg' })).toContain(
      'PNG or JPG',
    );
  });
});
