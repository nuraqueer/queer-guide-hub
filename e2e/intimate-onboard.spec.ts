import { test, expect } from '@playwright/test';

// Intimate onboarding gates (email-verification wall removed 2026-06-11).
// An authed user landing on /intimate/onboard reaches the stepper — never the
// old "Verify your email first" wall. Non-mutating: it never checks the consent
// box or advances the stepper, so no intimate profile row is created. The authed
// test uses the admin storageState from auth.setup and skips when
// E2E_ADMIN_EMAIL / E2E_ADMIN_PASSWORD are unset.
//
// THE 18+ STEP IS UNREACHABLE FOR AN ENROLLED ACCOUNT, AND EVERY ACCOUNT IS
// ENROLLED. `IntimateOnboard.tsx` computes
//   hasAgeConsent = affirmed || !!existing?.consent_18plus_at
// and then `if (s === 'consent') return !hasAgeConsent`, so the consent step is
// filtered OUT of the wizard once the account has consented and the user lands
// on the first remaining step. Measured on prod 2026-10-17: 19 profiles, 19
// intimate_profiles, **0 accounts without one**, and `auto_enroll_intimate_trg`
// (20260710110000) is live and enabled, so a new signup is enrolled on profile
// insert.
//
// That is a DELIBERATE PRODUCT DECISION, not fixture drift — that migration's
// header records the owner's "all users must have the same feature set" for this
// 18+ platform, with consent grounded in the required 18+ signup checkbox
// (`age_confirmed_at`). So this test asserted a state the platform no longer puts
// anyone in, and it failed every scheduled nightly.
//
// What holds in both states is this file's actual subject — the absent email
// wall — so that is asserted unconditionally, with the stepper as the positive
// control so the absence is not vacuous against a blank page, a gate or a 404.

const hasAuth = !!(process.env.E2E_ADMIN_EMAIL && process.env.E2E_ADMIN_PASSWORD);

test.describe('intimate onboarding', () => {
  test('reaches the stepper with no email-verification wall', async ({ page }) => {
    test.skip(!hasAuth, 'requires E2E_ADMIN_EMAIL / E2E_ADMIN_PASSWORD');
    await page.goto('/intimate/onboard');

    // POSITIVE CONTROL FIRST. Without it "no email wall" is equally true of a
    // loading state, a sign-in gate and a 404.
    await expect(page.getByRole('heading', { name: /intimate profile/i })).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.getByText(/Verify your email first/i)).toHaveCount(0);

    // The 18+ step exists only for an account that has not consented. Assert its
    // gate when it is there rather than assuming which state the fixture is in.
    const consent = page.getByText(/I confirm I am at least 18 years old/i);
    if ((await consent.count()) > 0) {
      await expect(consent).toBeVisible();
      // Next stays disabled until consent is given — the 18+ gate is load-bearing.
      await expect(page.getByRole('button', { name: /next/i })).toBeDisabled();
    }
  });

  test('anonymous user is asked to sign in, not shown the stepper', async ({ browser }) => {
    const anonContext = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const anonPage = await anonContext.newPage();
    await anonPage.goto('/intimate/onboard');
    await expect(anonPage.getByText(/sign in to continue/i)).toBeVisible();
    await expect(anonPage.getByText(/Verify your email first/i)).toHaveCount(0);
    await anonContext.close();
  });
});
