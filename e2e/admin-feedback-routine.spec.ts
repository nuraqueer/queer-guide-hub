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
    // 'stories' is the default tab, but name it: a later default change would
    // otherwise silently move this test to a tab with no stories on it.
    await gotoAdmin(page, '/admin/feedback?tab=stories', HEADING);

    // How many stories exist is on the toolbar toggle ("Active (12)"), so the
    // skip below can state a MEASURED reason instead of guessing. The first run
    // of this test with a real admin session (CI run 38946211881) reported
    // "no story present" — and that was NOT true of the data: it keyed on
    // `[data-testid="story-card"]`, a hook that exists nowhere in src/, so it
    // would have self-skipped forever however many stories there were. That is
    // the same vacuous-skip defect as the E2E_ADMIN_COOKIE gate itself, one
    // layer in.
    const activeToggle = page.getByTestId('stories-active-toggle');
    await expect(activeToggle).toBeVisible({ timeout: 15_000 });
    const activeLabel = (await activeToggle.textContent()) ?? '';
    const activeCount = Number(/\((\d+)\)/.exec(activeLabel)?.[1] ?? '0');
    test.skip(activeCount === 0, `no active story to open (toolbar reads "${activeLabel.trim()}")`);

    // A story card carries a stable test id ONLY in select mode
    // (`selectable-story-<uuid>` in StoriesKanban), so select mode is used
    // purely as an id source. The drawer is URL-driven — StoryDetailDrawer
    // opens on `!!state.story` — so navigating to ?story=<id> is the app's own
    // contract and avoids depending on card-click semantics, which select mode
    // deliberately changes from "open" to "select".
    await page.getByTestId('enter-select-mode').click();
    const firstCard = page.locator('[data-testid^="selectable-story-"]').first();
    await expect(firstCard, 'select mode exposed no story card').toBeVisible({ timeout: 15_000 });
    const storyId = (await firstCard.getAttribute('data-testid'))!.replace('selectable-story-', '');
    expect(storyId, 'could not read a story id out of the select-mode test id').toMatch(
      /^[0-9a-f-]{36}$/i,
    );

    await gotoAdmin(page, `/admin/feedback?tab=stories&story=${storyId}`, HEADING);

    // The routine loop section should render with at least one of the
    // approve/dispatch/run/verify cards visible.
    await expect(page.getByTestId('routine-loop')).toBeVisible({ timeout: 15_000 });

    // One of the action affordances must be present depending on phase.
    const anyAction = page
      .getByTestId('approve-for-claude')
      .or(page.getByTestId('dispatch-routine'))
      .or(page.getByTestId('routine-run-card'))
      .or(page.getByTestId('verify-card'))
      .or(page.getByTestId('archive-story'));
    await expect(anyAction.first()).toBeVisible({ timeout: 10_000 });
  });
});
