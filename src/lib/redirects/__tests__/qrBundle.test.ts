import sharp from 'sharp';
import jsQR from 'jsqr';
import JSZip from 'jszip';
import { execFileSync } from 'node:child_process';
import { afterEach, beforeEach, describe, it, expect, vi } from 'vitest';
import { buildQrBundle } from '../qrBundle';
import { DEFAULT_QR_STYLE, generateQr } from '../qr';
import { manualRedirect, type InventoryRedirect } from '../inventory';
// Real SVG/PNG/JPG rasterization in an isolated Node canvas adapter. This is not
// native-browser proof; the production generator and jsQR decoder run unchanged.
class RasterImage {
  src = '';
  pixels = new Uint8ClampedArray();
  png = '';
  jpg = '';
  async decode() {
    const input = this.src.startsWith('data:image/svg+xml;')
      ? Buffer.from(decodeURIComponent(this.src.split(',')[1]))
      : Buffer.from(this.src.split(',')[1], 'base64');
    const { data } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    this.pixels = new Uint8ClampedArray(data);
    this.png = 'data:image/png;base64,' + (await sharp(input).png().toBuffer()).toString('base64');
    this.jpg =
      'data:image/jpeg;base64,' +
      (await sharp(input).jpeg({ quality: 95 }).toBuffer()).toString('base64');
  }
}
beforeEach(() => {
  vi.stubGlobal('Image', RasterImage);
  vi.stubGlobal('document', {
    createElement: (tag: string) => {
      if (tag !== 'canvas') throw new Error('Unexpected element');
      let image: RasterImage;
      return {
        width: 1024,
        height: 1024,
        getContext: () => ({
          drawImage: (value: RasterImage) => {
            image = value;
          },
          getImageData: () => ({ data: image.pixels, width: 1024, height: 1024 }),
        }),
        toDataURL: (mime: string) => (mime === 'image/jpeg' ? image.jpg : image.png),
      };
    },
  });
});
afterEach(() => vi.unstubAllGlobals());
const row = (id: string, source: string): InventoryRedirect => ({
  ...manualRedirect({ id, type: 'SHORT', slug: 'fixture', target: '/events', is_enabled: true }),
  source,
});
describe('bulk verified QR ZIP', () => {
  it('exports scan-verified branded roots and slug links with QR attribution', async () => {
    const root = manualRedirect({
      id: 'root',
      type: 'SHORT',
      slug: 'internal-root',
      domain_id: 'domain',
      domain_hostname: 'links.community.com',
      is_domain_root: true,
      target: '/events',
      is_enabled: true,
    });
    const normal = { ...root, id: 'normal', source: 'https://links.community.com/pride' };
    const result = await buildQrBundle([root, normal], DEFAULT_QR_STYLE, 'png');
    const archive = await JSZip.loadAsync(Buffer.from(result.bytes));
    expect(await archive.file('manifest.csv')!.async('string')).toContain(
      'https://links.community.com/?qg_qr=1',
    );
    for (const file of Object.values(archive.files).filter((file) => file.name.endsWith('.png'))) {
      const bytes = await file.async('uint8array');
      const { data, info } = await sharp(bytes)
        .ensureAlpha()
        .raw()
        .toBuffer({ resolveWithObject: true });
      expect(jsQR(new Uint8ClampedArray(data), info.width, info.height)?.data).toBe(
        file.name.startsWith('001')
          ? 'https://links.community.com/?qg_qr=1'
          : 'https://links.community.com/pride?qg_qr=1',
      );
    }
  });
  it('exports every format with unique safe names and an accurate manifest, readable by Python ZIP', async () => {
    const rows = [
      row('one', '/go/pride?utm_source=print#details'),
      row('two', '/go/pride?utm_source=other'),
      row('three', '/events/community'),
    ];
    const progress: number[] = [];
    const bundle = await buildQrBundle(
      rows,
      { ...DEFAULT_QR_STYLE, dots: 'joined', border: 'rounded' },
      'all',
      { onProgress: (value) => progress.push(value) },
    );
    const archive = await JSZip.loadAsync(Buffer.from(bundle.bytes));
    const names = Object.keys(archive.files);
    expect(names).toHaveLength(10);
    expect(new Set(names).size).toBe(10);
    expect(names.every((name) => !name.includes('/') && !name.includes('..'))).toBe(true);
    const manifest = await archive.file('manifest.csv')!.async('string');
    expect(manifest).toContain('https://queer.guide/go/pride?utm_source=print&qg_qr=1#details');
    expect(manifest).toContain('https://queer.guide/events/community');
    expect(progress).toEqual([0, 1, 2, 3]);
    for (const name of names.filter((name) => name !== 'manifest.csv')) {
      const bytes = await archive.file(name)!.async('uint8array');
      const { data, info } = await sharp(bytes)
        .ensureAlpha()
        .raw()
        .toBuffer({ resolveWithObject: true });
      const decoded = jsQR(new Uint8ClampedArray(data), info.width, info.height)?.data;
      expect(decoded).toBe(
        name.startsWith('001')
          ? 'https://queer.guide/go/pride?utm_source=print&qg_qr=1#details'
          : name.startsWith('002')
            ? 'https://queer.guide/go/pride?utm_source=other&qg_qr=1'
            : 'https://queer.guide/events/community',
      );
    }
    const check = JSON.parse(
      execFileSync(
        'python3',
        [
          '-c',
          'import io,sys,zipfile,json; z=zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read())); print(json.dumps({"count":len(z.namelist()),"bad":z.testzip()}))',
        ],
        { input: Buffer.from(bundle.bytes), encoding: 'utf8' },
      ),
    );
    expect(check).toEqual({ count: 10, bad: null });
    expect(bundle.count).toBe(3);
  });
  it('reports the failing link after earlier verification without producing a partial archive', async () => {
    const progress: number[] = [];
    await expect(
      buildQrBundle(
        [row('one', '/go/one'), row('broken', '/go/' + 'x'.repeat(6000))],
        DEFAULT_QR_STYLE,
        'png',
        { onProgress: (count) => progress.push(count) },
      ),
    ).rejects.toThrow('Could not verify /go/');
    expect(progress).toEqual([0, 1]);
  });
  it('rejects invalid selections or styles before generating anything', async () => {
    await expect(buildQrBundle([], DEFAULT_QR_STYLE, 'png')).rejects.toThrow('1–100');
    await expect(
      buildQrBundle(Array(101).fill(row('one', '/go/one')), DEFAULT_QR_STYLE, 'png'),
    ).rejects.toThrow('1–100');
    await expect(
      buildQrBundle([row('one', '/go/one'), row('one', '/go/two')], DEFAULT_QR_STYLE, 'png'),
    ).rejects.toThrow('distinct');
    await expect(
      buildQrBundle([row('one', '/events/:slug')], DEFAULT_QR_STYLE, 'png'),
    ).rejects.toThrow('concrete URL');
    await expect(
      buildQrBundle(
        [row('one', '/go/one')],
        { ...DEFAULT_QR_STYLE, foreground: DEFAULT_QR_STYLE.background },
        'png',
      ),
    ).rejects.toThrow('contrast');
  });
  it('cancels before rendering and between verified links without returning a partial archive', async () => {
    const before = new AbortController();
    before.abort();
    await expect(
      generateQr('https://queer.guide/go/one', DEFAULT_QR_STYLE, before.signal),
    ).rejects.toMatchObject({ name: 'AbortError' });
    const run = new AbortController();
    const progress: number[] = [];
    await expect(
      buildQrBundle([row('one', '/go/one'), row('two', '/go/two')], DEFAULT_QR_STYLE, 'svg', {
        signal: run.signal,
        onProgress: (count) => {
          progress.push(count);
          if (count === 1) run.abort();
        },
      }),
    ).rejects.toMatchObject({ name: 'AbortError' });
    expect(progress).toEqual([0, 1]);
  });
});
