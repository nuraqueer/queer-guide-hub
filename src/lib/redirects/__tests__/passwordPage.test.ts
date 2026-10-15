import { describe, it, expect } from 'vitest';
import {
  passwordPageBranding,
  redirectPasswordPage,
} from '../../../../supabase/functions/_shared/redirect-password-page';
const asset = {
  id: 'd0000000-0000-4000-8000-000000000001',
  key: 'd0000000-0000-4000-8000-000000000001.png',
  mime: 'image/png',
  bytes: 100,
  width: 64,
  height: 64,
  sha256: 'a'.repeat(64),
};
describe('controlled password-page branding', () => {
  it('builds only fixed Storage URLs and escapes explicit public labels', async () => {
    const brand = passwordPageBranding(
      {
        brandName: 'Studio & <community>',
        logoAsset: { ...asset, url: 'https://private.example.org/track' },
      },
      'https://fixture.supabase.co',
    );
    expect(brand?.logo?.url).toBe(
      'https://fixture.supabase.co/storage/v1/object/public/redirect-brand-assets/' + asset.key,
    );
    const page = redirectPasswordPage(
      401,
      'Protected link',
      'Enter the password to open this link.',
      true,
      false,
      brand,
    );
    const html = await page.text();
    expect(html).toContain('Studio &amp; &lt;community&gt;');
    expect(html).toContain('crossorigin="anonymous" referrerpolicy="no-referrer"');
    expect(html).not.toContain('private.example.org');
    expect(html).toContain('<form method="post">');
    expect(page.headers.get('Content-Security-Policy')).toContain("form-action 'self'");
    expect(page.headers.get('Content-Security-Policy')).toContain(
      'img-src https://fixture.supabase.co',
    );
    expect(page.headers.get('Cache-Control')).toContain('no-store');
  });
  it('refuses malformed references and retains the password form without an image', async () => {
    for (const change of [
      { id: [asset.id] },
      { key: '../../private.svg' },
      { mime: 'image/svg+xml' },
      { width: 1025 },
      { sha256: ['a'.repeat(64)] },
    ]) {
      const brand = passwordPageBranding(
        { brandName: 'Safe label', logoAsset: { ...asset, ...change } },
        'https://fixture.supabase.co',
      );
      expect(brand?.logo).toBeNull();
      expect(
        await redirectPasswordPage(
          401,
          'Protected link',
          'Enter password.',
          true,
          false,
          brand,
        ).text(),
      ).toContain('name="password"');
    }
    expect(
      passwordPageBranding({ logoAsset: asset }, 'https://user:secret@fixture.supabase.co'),
    ).toBeNull();
    expect(
      passwordPageBranding({ brandName: 'bad\nlabel' }, 'https://fixture.supabase.co'),
    ).toBeNull();
  });
  it('keeps HEAD empty and throttled decoration free of destinations or secrets', async () => {
    const brand = passwordPageBranding(
      { brandName: 'Community', logoAsset: asset },
      'https://fixture.supabase.co',
    );
    expect(
      await redirectPasswordPage(
        401,
        'Protected link',
        'Enter password.',
        true,
        true,
        brand,
      ).text(),
    ).toBe('');
    const blocked = await redirectPasswordPage(
      429,
      'Try again later',
      'Wait before trying again.',
      false,
      false,
      brand,
    ).text();
    expect(blocked).toContain('Community');
    expect(blocked).not.toContain('<form');
    expect(blocked).not.toContain('password_hash');
  });
});
