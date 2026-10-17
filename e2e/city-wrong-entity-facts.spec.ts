import { test, expect } from '@playwright/test';

// A city page must never publish facts belonging to a DIFFERENT city of the
// same name.
//
// Measured 2026-09-18: 146 US city rows carried a `wikipedia_title` naming a
// city in a different US state, and 143 had already published from it —
// 139 postal codes, 114 area codes, 48 NAMED MAYORS. `Washington, D.C.` listed
// "Donald Sadler", the mayor of Washington, NORTH CAROLINA. Columbus, Ohio
// carried Columbus GEORGIA's mayor, universities and sister cities. Saint Paul,
// Minnesota carried the mayor of Saint-Paul, RÉUNION. Retracted in
// 99991789819768_city_wikidata_not_a_place.
//
// Publishing a named real person as the mayor of a city they have no connection
// to was the sharpest harm here, which is why it was the thing asserted.
//
// WHY THIS IS AN SPA SPEC AND NOT A CRAWLER-HTML ONE, unlike its tag siblings:
// verified against prod, the crawler HTML for /city/:slug renders venues,
// events and trip-planning only — it carries no factual block at all, so a
// crawler assertion here would be vacuously true. The fact rows are built in
// CityOverviewTab.tsx, i.e. client-side.
//
// EVERY NEGATIVE IS PAIRED WITH A POSITIVE, the discipline the tag specs use:
// "does not mention Donald Sadler" passes on a 404, on an empty render, and on
// a page that failed to load. So each repaired city must first prove it
// rendered, and ONE CASE IS THE WHOLE-FILE CONTROL. Without it this file would
// pass against a build that simply stopped rendering the fact block.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE CONTROL FIRED, AND IT WAS RIGHT TWICE OVER (2026-10-17).
//
// It read "Berlin still publishes its own real mayor" and asserted `Kai Wegner`.
// Two separate things had happened since this file was written on 2026-09-19,
// and each on its own makes every negative above vacuous:
//
//  1. `cities.mayor` IS GONE. 99991791530305_drop_city_mayor dropped it from
//     `cities` AND `geo_city_profiles` — explicitly because it was "the field
//     with the worst record of wrong-entity harm", citing Buenos Aires
//     publishing a Córdoba town's mayor and Frisco TX serving San Francisco's.
//     So the remedy for the defect this file guards was to delete the field, and
//     no city publishes a mayor now. The four mayor needles below can no longer
//     fail; they are kept as a guard against the column being reintroduced with
//     the same data, not as evidence of anything today.
//
//  2. THE FACT BLOCK IS COLLAPSED. #4272 ("Simplify city pages with subway
//     wayfinding", 2026-10-10) made the About section `presentation:
//     'disclosure'`, and this file read `body.innerText`, which excludes
//     collapsed content. Measured on prod: `innerText` for /city/berlin contains
//     none of Postal codes / Region / Elevation / Status, while `innerHTML`
//     contains the postal code. So from 10-10 onward EVERY assertion here —
//     mayors, postal codes, universities, the Réunion prose — was reading a
//     surface the facts are not on, and the file was green for that reason
//     rather than for the repair holding.
//
// Setting `open` on every <details> does NOT fix it (measured: innerText grows
// by 19 characters) — the disclosure is not a native one.
//
// SO THE SURFACE IS NOW `textContent`, NOT `innerText`, and that is the right
// surface for the claim rather than a workaround: this file asks whether a wrong
// city's facts are PUBLISHED, and a collapsed disclosure publishes them — it is
// one click from a reader and already in the markup. The cost, stated because it
// is a real widening: `textContent` also includes JSON-LD and any other
// script-embedded text, so a name present only in structured data now trips a
// negative. For a "must never publish" assertion that is correct.
//
// THE CONTROL IS NOW BERLIN'S POSTAL CODE, chosen because it is the same fact
// row as three of the needles below. Measured 2026-10-17: Berlin's `textContent`
// carries "Postal codes" and "10115" (its range is 10115–14199) while all four
// repaired cities carry NONE of the twelve needles — so the negatives are
// non-vacuous again.
//
// `universities` needles are KEPT AND CANNOT FIRE: measured, no `.tsx` in the
// repo reads that column, so it reaches no surface at all. They would catch a
// future render of refilled wrong-city data; they prove nothing now.
// ─────────────────────────────────────────────────────────────────────────────

const BASE = process.env.E2E_BASE_URL ?? 'https://queer.guide';

interface Case {
  slug: string;
  /** Proof the page actually rendered. */
  present: RegExp;
  /** Facts belonging to the wrong same-name city. */
  absent: { needle: RegExp; why: string }[];
}

const REPAIRED: Case[] = [
  {
    slug: 'washington-d-c',
    present: /Washington/i,
    absent: [
      { needle: /Donald\s+Sadler/i, why: 'mayor of Washington, North Carolina' },
      { needle: /\b27889\b/, why: 'Washington NC postal code' },
    ],
  },
  {
    slug: 'columbus',
    present: /Columbus/i,
    absent: [
      { needle: /Skip["\s]*Henderson/i, why: 'mayor of Columbus, Georgia' },
      { needle: /Columbus State University/i, why: 'a Columbus, Georgia university' },
      { needle: /\b31901\b/, why: 'Columbus GA postal code' },
    ],
  },
  {
    slug: 'saint-paul',
    present: /Saint\s*Paul/i,
    absent: [
      { needle: /Joseph\s+Sinimal/i, why: 'mayor of Saint-Paul, Réunion' },
      { needle: /\b97411\b/, why: 'a Réunion postal code' },
      // The description opened "the second-largest commune in the French
      // overseas department of Réunion" — on a Minnesota page. Retracted by
      // 20260919140930, guarded on the prose naming the wrong place.
      { needle: /R[ée]union/i, why: "Saint-Paul, Réunion's description" },
    ],
  },
  {
    // The non-US half of the same defect (20260919141647). León, Guanajuato
    // carried Q15699 — León, SPAIN — and published its mayor, postcodes, area
    // code, twinnings and university. Its Mexican description and population
    // came from elsewhere and are correct, which is why they are asserted to
    // SURVIVE in the test below rather than merely left alone.
    slug: 'leon',
    present: /Le[oó]n/i,
    absent: [
      { needle: /Jos[ée]\s+Antonio\s+Diez/i, why: 'mayor of León, SPAIN' },
      { needle: /24001/, why: 'a León, Spain postal code' },
      { needle: /University of Le[oó]n/i, why: "León Spain's university" },
    ],
  },
];

/**
 * Give the SPA a chance to hydrate and paint, then read what the page PUBLISHES.
 *
 * `textContent`, not `innerText`: the About section is a collapsed disclosure
 * (#4272), and `innerText` omits collapsed content — see the header. Collapsed
 * is still published, so this is the surface the claim is about.
 */
async function cityText(page: import('@playwright/test').Page, slug: string) {
  const res = await page.goto(`${BASE}/city/${slug}`, {
    waitUntil: 'domcontentloaded',
    timeout: 45_000,
  });
  expect(res?.status(), `${slug} must not 404`).toBeLessThan(400);
  await page.waitForLoadState('networkidle', { timeout: 45_000 }).catch(() => {});
  return ((await page.locator('body').textContent()) ?? '').replace(/\s+/g, ' ');
}

test.describe('city pages do not publish another same-name city’s facts', () => {
  for (const c of REPAIRED) {
    test(`/city/${c.slug}`, async ({ page }) => {
      const text = await cityText(page, c.slug);

      // Positive first: without this every negative below is vacuous.
      expect(text, `${c.slug} did not render`).toMatch(c.present);
      expect(text.length, `${c.slug} rendered an empty body`).toBeGreaterThan(200);

      for (const { needle, why } of c.absent) {
        expect(text, `/city/${c.slug} still publishes ${needle} — ${why}`).not.toMatch(needle);
      }
    });
  }

  test('control: León keeps its own correct Mexican prose', async ({ page }) => {
    // The repair retracted every Wikidata-derived field on this row but NOT the
    // description or population, which came from another source and are right.
    // Without this the León case above would also pass against a pass that
    // simply blanked the page — the over-reach the migrations argue against.
    const text = await cityText(page, 'leon');
    expect(text, 'León lost its correct Mexican description').toMatch(/Guanajuato/i);
  });

  test('control: Berlin still publishes its own fact rows', async ({ page }) => {
    // THE WHOLE-FILE CONTROL. If this fails, the fact block stopped reaching the
    // page for everyone and every assertion above is passing for the wrong
    // reason — which is exactly what happened between 2026-10-10 and 2026-10-17
    // and what the previous version of this test reported.
    //
    // It asserted Berlin's mayor, and `cities.mayor` has since been dropped
    // platform-wide (see the header), so it can never pass again. Postal codes
    // replace it deliberately: that is the SAME fact row three of the needles
    // above are about, so proving it renders is what makes those non-vacuous.
    // A mayor-shaped control could not do that even if the column returned.
    const text = await cityText(page, 'berlin');
    expect(text).toMatch(/Berlin/i);
    expect(text, 'the fact block is gone — the negatives above are now vacuous').toMatch(
      /Postal codes/i,
    );
    // Berlin's own range is 10115–14199. Asserted on the leading digits so an
    // en-dash or a formatting change does not read as a missing fact.
    expect(text, 'Berlin lost its own postal code — the negatives above are now vacuous').toMatch(
      /10115/,
    );
  });
});
