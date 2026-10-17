import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { gotoReady } from './support/appReady';
import { REDUCED_MOTION } from './support/reducedMotion';

// Read-only release coverage. Always use a fresh signed-out context, even when
// the workflow also authenticates its admin fixture for other spec files.
test.use({ ...REDUCED_MOTION, locale: 'en-US', storageState: { cookies: [], origins: [] } });
test.setTimeout(120_000);

test.beforeEach(async ({ page }) => {
  await gotoReady(page, '/tags');
  await expect(
    page.getByRole('searchbox', { name: 'Search the glossary', exact: true }),
  ).toBeVisible({
    timeout: 45_000,
  });
  const necessary = page.getByRole('button', { name: 'Necessary Only', exact: true });
  if (await necessary.isVisible()) await necessary.click();
});

test('search opens a definition and Back restores the search', async ({ page }) => {
  const search = page.getByRole('searchbox', { name: 'Search the glossary', exact: true });
  await search.fill('bisexual');
  await expect(page).toHaveURL(/\/tags\?q=bisexual$/);
  await page.locator('main a[href="/tags/bisexual"]').click();
  await expect(page.getByRole('heading', { level: 1, name: 'Bisexual', exact: true })).toBeVisible({
    timeout: 30_000,
  });
  await page.goBack();
  await expect(search).toHaveValue('bisexual');
  await expect(page).toHaveURL(/\/tags\?q=bisexual$/);
});

test('dictionary terms are the default and explicit All survives reload', async ({ page }) => {
  const kinds = page.getByRole('group', { name: 'Filters', exact: true });
  await expect(kinds.getByRole('button', { name: 'Terms', exact: true })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  // ASKED THROUGH SEARCH, because the default grid is no longer the whole corpus.
  //
  // This asserted `size-m` absent from the unsearched grid and present after
  // switching to All. Measured on prod 2026-10-17: the landing grid renders ~31
  // links and most are CATEGORY links (`/tags/c/...`), not terms — `size-m` is in
  // NEITHER kind's default view and there is no Load more, so the positive half
  // failed for a reason that has nothing to do with the kind filter.
  //
  // The claim worth keeping is the DISCRIMINATION — a label-kind term is withheld
  // from Terms and included in All — and search is where that stays observable
  // however much of the corpus the grid chooses to show. Measured both ways on the
  // same page: 0 under Terms, 1 under All.
  const search = page.getByRole('searchbox', { name: /search the glossary/i });
  await search.fill('size m');
  await expect(page.locator('main a[href^="/tags/size-m"]')).toHaveCount(0);
  await kinds.getByRole('button', { name: 'All', exact: true }).click();
  await expect(page).toHaveURL(/kind=all/);
  await expect(page.locator('main a[href^="/tags/size-m"]')).toBeVisible();
  await page.reload();
  await expect(kinds.getByRole('button', { name: 'All', exact: true })).toHaveAttribute(
    'aria-pressed',
    'true',
    { timeout: 45_000 },
  );
});

test('labels remain searchable without unrelated encyclopedia previews', async ({ page }) => {
  await page.getByRole('button', { name: 'Labels', exact: true }).click();
  await page.getByRole('searchbox', { name: 'Search the glossary', exact: true }).fill('size-m');
  await expect(page.locator('main a[href="/tags/size-m"]')).toBeVisible();
  await expect(page.locator('main')).not.toContainText('thirteenth letter');
});

test('category changes expose the correct subcategories', async ({ page }) => {
  const rail = page.getByRole('navigation', { name: 'Topic lines', exact: true });
  // THE CATEGORY NAME IS AN h2, NOT THE h1. Measured on prod 2026-10-17: on
  // /tags/c/identity the only h1 is "Knowledge" — the page-level title shared by
  // every category — and the category itself is the first h2 ("Identity", followed
  // by "Looking for something else?"). So `heading level 1` resolved to
  // "Knowledge" and all three assertions here failed on a heading that is not the
  // one this test is about.
  //
  // Located BY NAME at level 2 rather than positionally: `main h2` carries more
  // than one heading, so `.first()` would pass today and silently start asserting
  // a different heading the moment one is inserted above it.
  await rail.getByRole('link', { name: /^Identity/ }).click();
  await expect(
    page.getByRole('heading', { level: 2, name: 'Identity', exact: true }),
  ).toBeVisible();
  await expect(
    rail.getByRole('button', { name: 'Hide stops on Identity', exact: true }),
  ).toHaveAttribute('aria-expanded', 'true');
  await rail.getByRole('link', { name: /^Health/ }).click();
  await expect(page.getByRole('heading', { level: 2, name: 'Health', exact: true })).toBeVisible();
  await expect(
    rail.getByRole('button', { name: 'Hide stops on Health', exact: true }),
  ).toHaveAttribute('aria-expanded', 'true');
  await rail.getByRole('link', { name: /^Mental/ }).click();
  await expect(page).toHaveURL(/\/tags\/c\/mental-health$/);
  await expect(page.getByRole('heading', { level: 2, name: 'Mental', exact: true })).toBeVisible();
  await expect(page.getByText(/terms · .* lines · .* stops/)).toHaveCount(0);
});

test('all four views render and default Grid keeps a clean URL', async ({ page }) => {
  for (const mode of ['List', 'Chips', 'Graph', 'Grid']) {
    const tab = page.getByRole('tab', { name: mode, exact: true });
    await tab.click();
    await expect(tab).toHaveAttribute('aria-selected', 'true');
    if (mode === 'Graph') {
      await expect(page.getByText(/\d+\s+tags?,\s+\d+\s+links?/i)).toBeVisible({ timeout: 45_000 });
      await expect(page.getByTestId('tag-graph-error')).toHaveCount(0);
    }
  }
  await expect(page).toHaveURL(/\/tags$/);
});

test('keyboard arrows switch views and move focus', async ({ page }) => {
  await page.getByRole('tab', { name: 'Grid', exact: true }).focus();
  await page.keyboard.press('ArrowRight');
  const list = page.getByRole('tab', { name: 'List', exact: true });
  await expect(list).toBeFocused();
  await expect(list).toHaveAttribute('aria-selected', 'true');
  await expect(page).toHaveURL(/view=list/);
  await page.keyboard.press('Home');
  await expect(page.getByRole('tab', { name: 'Grid', exact: true })).toBeFocused();
  await expect(page).toHaveURL(/\/tags$/);
});

test('letter selection survives reload', async ({ page }) => {
  const letter = page.getByRole('button', { name: 'Terms starting with B', exact: true });
  await letter.click();
  await expect(page).toHaveURL(/letter=B/);
  await page.reload();
  await expect(letter).toHaveAttribute('aria-pressed', 'true', { timeout: 45_000 });
  const titles = page.locator('main a.card-lift .text-title');
  await expect(titles.first()).toBeVisible();
  for (const title of await titles.allTextContents()) expect(title.trim()).toMatch(/^B/i);
});

test('empty results offer a working reset', async ({ page }) => {
  await page
    .getByRole('searchbox', { name: 'Search the glossary', exact: true })
    .fill('qg-e2e-no-such-term-876532109');
  await expect(page.getByRole('heading', { name: /No terms match/ })).toBeVisible();
  await page.getByRole('button', { name: 'Reset filters', exact: true }).first().click();
  await expect(page).toHaveURL(/\/tags$/);
  await expect(
    page.getByRole('searchbox', { name: 'Search the glossary', exact: true }),
  ).toHaveValue('');
  await expect(page.locator('main a.card-lift').first()).toBeVisible();
});

for (const width of [320, 390, 1280]) {
  test(`glossary reflows and shows labelled controls at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    await expect(page.getByRole('heading', { level: 1 })).toHaveCount(1);
    for (const mode of ['Grid', 'List', 'Chips', 'Graph']) {
      await expect(page.getByRole('tab', { name: mode, exact: true })).toBeVisible();
    }
    await expect(page.locator('main a.card-lift').first()).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow, 'the document must not scroll sideways').toBeLessThanOrEqual(0);
    const path = testInfo.outputPath(`glossary-${width}.png`);
    await page.screenshot({ path });
    await testInfo.attach(`glossary-${width}`, { path, contentType: 'image/png' });
  });
}

for (const width of [320, 1280]) {
  test(`glossary has no serious or critical accessibility violations at ${width}px`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height: 900 });
    await expect(page.locator('main a.card-lift').first()).toBeVisible();
    const results = await new AxeBuilder({ page })
      .include('main')
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'])
      .analyze();
    const blocking = results.violations.filter(
      (v) => v.impact === 'serious' || v.impact === 'critical',
    );
    expect(blocking, JSON.stringify(blocking, null, 2)).toEqual([]);
  });
}
