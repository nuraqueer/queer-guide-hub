import sharp from 'sharp';
import { describe, expect, it } from 'vitest';
import {
  presentationPage,
  previewImageInfo,
  socialPreviewAgent,
} from '../../../../supabase/functions/_shared/redirect-presentation';
import { policyErrors } from '../../../../supabase/functions/_shared/link-policy';
describe('redirect presentation', () => {
  it('escapes preview metadata and keeps iframe fallback accessible with no scripts', async () => {
    const response = presentationPage(
      {
        title: '"><script>alert(1)</script>',
        description: 'A & B',
        image: 'https://example.com/art.png',
        video: 'https://example.com/video.mp4',
      },
      'https://queer.guide/go/pride',
      'https://example.com/?q=a%26b',
      true,
    );
    const html = await response.text();
    expect(html).not.toContain('<script>');
    expect(html).toContain('&lt;script&gt;');
    expect(html).toContain('property="og:video"');
    expect(html).toContain('property="og:image"');
    expect(html).toContain('Open destination directly');
    expect(html).toContain('This site may block framed pages');
    expect(response.headers.get('Content-Security-Policy')).toContain(
      'frame-src https://example.com',
    );
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(
      await presentationPage(
        {},
        'https://queer.guide/go/pride',
        'https://example.com',
        false,
        true,
      ).text(),
    ).toBe('');
  });
  it('validates preview field lengths, closed settings and HTTPS media URLs', () => {
    expect(
      policyErrors({
        preview: {
          title: 'x'.repeat(120),
          description: 'y'.repeat(240),
          image: 'https://example.com/image.png',
        },
        cloaked: true,
      }),
    ).toEqual([]);
    for (const policy of [
      { preview: { title: 'x'.repeat(121) } },
      { preview: { description: 'y'.repeat(241) } },
      { preview: { image: 'javascript:alert(1)' } },
      { preview: { video: 'http://example.com/a.mp4' } },
      { preview: { image: 'https://127.0.0.1/a.png' } },
      { preview: { unknown: true } },
      { cloaked: 'yes' },
    ])
      expect(policyErrors(policy as never).length).toBeGreaterThan(0);
    expect(socialPreviewAgent('facebookexternalhit/1.1')).toBe(true);
    expect(socialPreviewAgent('Mozilla/5.0')).toBe(false);
  });
  it('detects real PNG/JPG dimensions and rejects SVG, oversized and malformed uploads', async () => {
    for (const format of ['png', 'jpeg'] as const) {
      const bytes = await sharp({
        create: { width: 1200, height: 630, channels: 3, background: '#ffeecc' },
      })
        .toFormat(format)
        .toBuffer();
      expect(previewImageInfo(bytes)).toMatchObject({
        width: 1200,
        height: 630,
        mime: format === 'png' ? 'image/png' : 'image/jpeg',
      });
    }
    expect(() =>
      previewImageInfo(new TextEncoder().encode('<svg onload="alert(1)"></svg>')),
    ).toThrow();
    expect(() => previewImageInfo(new Uint8Array(1500001))).toThrow();
    expect(() => previewImageInfo(new Uint8Array([255, 216, 255, 192, 0, 0, 255, 217]))).toThrow();
  });
});
