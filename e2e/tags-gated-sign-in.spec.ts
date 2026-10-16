import { test, expect } from '@playwright/test';

// A gated glossary term must answer a signed-out reader "sign in", not "no such
// thing" — and must still answer a crawler with nothing.
//
// `unified_tags_public_gated_read` admits anon only when a tag is non-sensitive
// OR its `verification_status` is 'reviewed'/'locked'. Measured on prod
// 2026-09-03: 101 active tags are sensitive AND unverified — the glossary cohort
// created by 20261211100000 / 100100 / 20261217100000 — and every one HARD 404'd
// for a signed-out visitor while rendering in full for a signed-in one. A real
// term was indistinguishable from a typo.
//
// Discipline copied from tags-positions-gated.spec.ts and tags-wrong-sense.spec.ts:
// raw HTTP (~0.4s a GET, and signed-out by construction — the default project
// carries an admin storageState when creds are set, which is exactly the trap
// that broke earlier signed-out specs), and every negative paired with a
// POSITIVE CONTROL, because "does not contain the definition" is vacuously true
// of a 404 and of an empty body.

const BOT_UA = 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)';

/** `<meta name="robots" content="...">`, lower-cased, or '' when absent. */
function robotsOf(html: string): string {
  const m = html.match(/<meta[^>]+name=["']robots["'][^>]*content=["']([^"']*)["']/i);
  return m ? m[1].toLowerCase() : '';
}

/** `<title>`, or '' when absent. */
function titleOf(html: string): string {
  const m = html.match(/<title>([\s\S]*?)<\/title>/i);
  return m ? m[1] : '';
}

/**
 * Does the crawler document publish the term as structured content?
 *
 * This is the paired fingerprint, and it replaced an assertion on the
 * `<main data-prerendered="bot-ua">` block that was WRONG — measured on prod
 * 2026-09-04, that block is absent from BOTH a gated tag and a readable one.
 * `functions/_middleware.ts` gates the body injection on
 * `indexable && isBotUserAgent(...)`, and every tag in this cohort (gated or
 * not) is `seo_indexable=false`, so the block never appears and asserting its
 * presence would fail nightly while proving nothing. `DefinedTerm` JSON-LD does
 * discriminate: `tagDetail` emits it for a readable tag and `gatedDetailResult`
 * emits no JSON-LD at all.
 */
function publishesDefinedTerm(html: string): boolean {
  return html.includes('DefinedTerm');
}

/**
 * THE COHORT IS A MOVING SET, AND PINNING FOUR OF IT HAS NOW FAILED TWICE.
 *
 * Round one: `footjob` was removed on 2026-09-04 because 20270107114500
 * published it, and `bagpiping` took its place. Round two: measured on prod
 * 2026-10-16, ALL FOUR of `bagpiping`/`anal-whore`/`gag-slut`/`spit-slut` are
 * now `verification_status='reviewed'` and therefore readable — they serve their
 * own `DefinedTerm` page, so every case failed every scheduled nightly. The
 * header above already predicted this and said to check the flag first; the flag
 * says *published*, so this is a sample that rotted and not a regression.
 *
 * The cohort itself collapsed: **101 rows when this spec was written, 8 now.**
 * A fifth hand-picked sample would rot the same way and faster, because four of
 * the eight are `auto`/`unverified` rows that the glossary passes keep reviewing.
 *
 * So the list is the WHOLE live cohort rather than a sample of it, and each case
 * asserts the invariant for whichever state the row is in. That invariant is the
 * one thing that must never be true again — a gated term answering 404, which is
 * what 101 rows did to signed-out visitors before this file existed — and it is
 * asserted for a published row too, because a 404 is wrong in both states.
 * Membership is not the invariant, so a review no longer breaks the suite.
 *
 * Re-select with:
 *   select slug from unified_tags
 *    where status='active' and is_sensitive
 *      and coalesce(verification_status,'') not in ('reviewed','locked')
 *    order by slug;
 *
 * Measured 2026-10-16, all eight: HTTP 200, `noindex,nofollow`, no DefinedTerm,
 * title "Sign in to view". The four published ones: 200, `noindex,nofollow`,
 * DefinedTerm present, own title — so publishing a sensitive row made it
 * readable on the site WITHOUT making it indexable, which is why `noindex` is
 * asserted unconditionally below and the shape check is what branches.
 */
const CANDIDATES = [
  'antiretroviral',
  'credibility-assessment',
  'intersex-genital-mutilation',
  'labia',
  'puberty',
  'rainbow-kiss',
  'sex-worker',
  'sexual-arousal',
];

/** Is this the gated document rather than the term's own page? */
function isGatedDocument(html: string): boolean {
  return /sign in to view/i.test(titleOf(html));
}

test.describe('@safety gated glossary terms', () => {
  for (const slug of CANDIDATES) {
    test(`/tags/${slug} answers a gate or its own page, never a 404`, async ({ request }) => {
      const res = await request.get(`/tags/${slug}`, { headers: { 'User-Agent': BOT_UA } });
      // THE INVARIANT, and it holds in both states. 404 here means the edge
      // conceded the term does not exist and the SPA never mounted, so no gate
      // can render — which is exactly what 101 rows did before this file.
      expect(res.status(), `${slug} must not 404 for a signed-out visitor`).toBe(200);

      const html = await res.text();
      // Withheld from the index either way — a sign-in wall is not a page to
      // rank, and a published sensitive row is still seo_indexable=false.
      // Measured 2026-10-16 on all twelve rows across both states.
      expect(robotsOf(html), `${slug} must stay noindex`).toContain('noindex');

      if (isGatedDocument(html)) {
        // Still gated. The term must not travel as content: the row is
        // unreviewed machine-written material, and `seo_indexable=false`
        // suppresses indexing, not the bytes we hand over.
        expect(publishesDefinedTerm(html), `${slug} must publish no DefinedTerm`).toBe(false);
      } else {
        // Published since this list was taken, which is a legitimate editorial
        // move and not a failure — but it must be a REAL page and not a husk.
        // Without this branch a blank 200 would read as "published" and the
        // case would pass having checked nothing.
        expect(
          publishesDefinedTerm(html),
          `${slug} is neither gated nor readable — it serves a 200 with no gate and no DefinedTerm`,
        ).toBe(true);
      }
      // The slug is deliberately NOT asserted absent: it is echoed in
      // `<link rel="canonical">` and `og:url`, which is the URL the crawler
      // asked for, not a disclosure of the definition.
    });
  }

  // ANTI-VACUITY CONTROL. The loop above tolerates a published row, so if the
  // whole cohort were reviewed it would pass while asserting nothing about the
  // gate. This fails instead, and names the query to re-select with.
  //
  // It re-fetches rather than sharing a tally with the loop: `fullyParallel` is
  // true in playwright.config.ts, so tests in this file can land in different
  // workers and cross-test state is not reliable.
  test('at least one candidate is still gated', async ({ request }) => {
    const gated: string[] = [];
    for (const slug of CANDIDATES) {
      const res = await request.get(`/tags/${slug}`, { headers: { 'User-Agent': BOT_UA } });
      if (res.status() === 200 && isGatedDocument(await res.text())) gated.push(slug);
    }
    expect(
      gated.length,
      `every candidate has been published, so the gate is no longer under test. Re-select:\n` +
        `  select slug from unified_tags where status='active' and is_sensitive\n` +
        `    and coalesce(verification_status,'') not in ('reviewed','locked') order by slug;`,
    ).toBeGreaterThan(0);
  });

  // NO BROWSER-RENDERED CASE HERE, AND THAT IS A DELIBERATE OMISSION.
  //
  // A `page.goto('/tags/footjob')` + "expect the gate heading" test was written,
  // run against prod on 2026-09-04, and REMOVED because it does not pass
  // reliably: in a cold Playwright context the page sits on its loading state
  // past both 15s and 30s and never reaches the gate OR the not-found branch.
  // The same URL renders the gate correctly in a warm browser — verified by
  // hand the same day (h1 "Sign in to view this term", the glossary copy, the
  // Sign in CTA). So the behaviour is right and the ASSERTION is what was
  // unreliable; the cause is a client fetch that does not settle on a cold
  // boot, which is not this change's to diagnose.
  //
  // Shipping it anyway would have put a nightly-red test in the suite, and a
  // suite people learn to ignore is worse than a smaller honest one. The SPA
  // branch is covered deterministically instead by three mutation-tested cases
  // in src/pages/__tests__/TagDetail.test.tsx (gate shown, place-gate copy NOT
  // borrowed, noIndex preserved). What is asserted here is the crawler surface,
  // which is where the 404 actually lived.

  // POSITIVE CONTROL. `kink` is sensitive too, but reviewed, so anon reads it.
  // Without this the spec above passes on a site where every tag is gated.
  test('a reviewed sensitive term still renders in full', async ({ request }) => {
    const res = await request.get('/tags/kink', { headers: { 'User-Agent': BOT_UA } });
    expect(res.status()).toBe(200);
    const html = await res.text();
    // The other half of the pair. `kink` is sensitive too and differs only in
    // being reviewed, so this is what makes the two assertions above
    // discriminating rather than true of every tag page.
    expect(titleOf(html)).toMatch(/kink/i);
    expect(titleOf(html)).not.toMatch(/sign in to view/i);
    expect(publishesDefinedTerm(html), 'a readable tag must publish DefinedTerm').toBe(true);
  });

  // NEGATIVE CONTROL. The 404 must still exist. If `gated_entity_exists` ever
  // answered true too broadly, every typo would get a sign-in gate and the
  // glossary would lose its 404 entirely.
  test('an unknown slug is still a hard 404', async ({ request }) => {
    const res = await request.get('/tags/asdfgibberish-not-a-real-tag-90210', {
      headers: { 'User-Agent': BOT_UA },
    });
    expect(res.status()).toBe(404);
  });

  // A merged tag is gated-shaped but is NOT gated — it has a live canonical one
  // hop away, and a sign-in gate there would swallow the 301.
  test('a merged slug still 301s rather than offering a gate', async ({ request }) => {
    const res = await request.get('/tags/rack', { headers: { 'User-Agent': BOT_UA } });
    expect(res.url()).toContain('/tags/risk-aware-consensual-kink');
    expect(await res.text()).not.toMatch(/sign in to view this term/i);
  });
});
