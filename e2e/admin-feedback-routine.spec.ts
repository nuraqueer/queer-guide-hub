import { test, expect } from '@playwright/test';
import { authenticated, ADMIN_SESSION_REQUIRED, gotoAdmin } from './support/adminAuth';

/**
 * Smoke for the feedback → Claude routine loop UI.
 *
 * The full happy path (approve → dispatch → retest → verify → archive) is
 * intentionally not seeded here: writing through admin RPCs against the
 * production project would mutate real data. When a staging project lands, swap
 * the SUPABASE_* env vars so this can run against an isolated DB and seed its
 * own story.
 *
 * Gating moved off `E2E_ADMIN_COOKIE` (which nothing has ever set, so this test
 * had never run anywhere) onto the storageState session the config already
 * attaches. See e2e/support/adminAuth.ts.
 */

const HEADING = 'Feedback & Errors';

test.describe('Admin feedback — routine loop UI', () => {
  test.skip(!authenticated, ADMIN_SESSION_REQUIRED);

  test('story drawer mounts the routine loop section', async ({ page }) => {
    await gotoAdmin(page, '/admin/feedback', HEADING);

    // Switch to Stories tab if present
    const storiesTab = page.getByRole('button', { name: /Stories/i }).first();
    if (await storiesTab.count()) {
      await storiesTab.click().catch(() => {
        /* tab may be hidden if no data */
      });
    }

    // Open the first story card if any.
    const firstCard = page.locator('[data-testid="story-card"], [data-story-card]').first();
    if (!(await firstCard.count())) {
      test.skip(true, 'no story present to exercise drawer');
      return;
    }
    await firstCard.click();

    // The routine loop section should render with at least one of the
    // approve/dispatch/run/verify cards visible.
    await expect(page.getByTestId('routine-loop')).toBeVisible({ timeout: 10_000 });

    // One of the action affordances must be present depending on phase.
    const anyAction = page
      .getByTestId('approve-for-claude')
      .or(page.getByTestId('dispatch-routine'))
      .or(page.getByTestId('routine-run-card'))
      .or(page.getByTestId('verify-card'))
      .or(page.getByTestId('archive-story'));
    await expect(anyAction.first()).toBeVisible({ timeout: 5_000 });
  });
});
