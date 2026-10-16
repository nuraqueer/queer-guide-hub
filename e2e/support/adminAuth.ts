import { expect, type Page } from '@playwright/test';

/**
 * Admin-session gating for e2e specs, with a positive control.
 *
 * Three specs (admin-feedback, admin-feedback-routine, admin-pipelines) gated
 * their authenticated halves on `E2E_ADMIN_COOKIE` and injected an
 * `sb-access-token` cookie themselves. NO workflow and no config has ever set
 * that variable — `grep -rn E2E_ADMIN_COOKIE .github/ playwright.config.ts`
 * hits only those spec files — so every one of those tests skipped in every
 * environment while the specs reported green. Measured 2026-10-15:
 * `admin-feedback.spec.ts` against prod returned 1 passed / 6 skipped, the one
 * that ran being an unauthenticated shell check.
 *
 * The session this repo actually uses comes from `playwright.config.ts`, which
 * attaches `storageState` to the chromium project when E2E_ADMIN_EMAIL +
 * E2E_ADMIN_PASSWORD are present (the nightly supplies both). So gate on that
 * pair — never on a cookie nothing sets.
 */
export const authenticated = Boolean(
  process.env.E2E_STORAGE_STATE || (process.env.E2E_ADMIN_EMAIL && process.env.E2E_ADMIN_PASSWORD),
);

export const ADMIN_SESSION_REQUIRED = 'Requires the configured admin session';

/**
 * Navigate to an admin route and assert we are actually ON it.
 *
 * This is the positive control, and it is not decoration. An anonymous visit to
 * any `/admin/*` route lands on `/auth`, where most of these specs' assertions
 * are vacuously satisfiable — and a "no error banner" or "no runtime crash"
 * check passes there outright. `/admin/inbox` served an error banner for six
 * weeks while `a11y-admin.spec.ts` stayed green for exactly that reason: an
 * error banner has no accessibility violations.
 *
 * Asserting the page's own <h1> means an auth regression fails here, loudly,
 * naming the cause — instead of surfacing as a confusing selector miss three
 * assertions later, or (worse) as a silent skip.
 */
export async function gotoAdmin(page: Page, url: string, heading: string) {
  await page.goto(url);
  await expect(
    page.getByRole('heading', { name: heading, exact: true }),
    `Not signed in as admin: ${url} did not render its "${heading}" heading (an anonymous visit lands on /auth)`,
  ).toBeVisible({ timeout: 15_000 });
}
