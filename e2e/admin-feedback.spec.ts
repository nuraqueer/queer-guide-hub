import { test, expect, type Page } from '@playwright/test';
import { authenticated, ADMIN_SESSION_REQUIRED, gotoAdmin } from './support/adminAuth';

/**
 * E2E smoke tests for /admin/feedback.
 * Unauthenticated tests verify the app shell loads without runtime errors.
 * Authenticated tests cover tab nav, kanban rendering, drawer interactions,
 * and the shortcut help overlay.
 *
 * Gating moved off `E2E_ADMIN_COOKIE` (which nothing has ever set, so all six
 * authenticated tests had never run anywhere) onto the storageState session the
 * config already attaches. See e2e/support/adminAuth.ts.
 */

const HEADING = 'Feedback & Errors';

async function waitForAppReady(page: Page) {
  await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {
    /* ignore */
  });
}

test.describe('Admin feedback — unauthenticated', () => {
  test('reaches /admin/feedback without runtime crash', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err) => errors.push(err.message));

    const response = await page.goto('/admin/feedback', { waitUntil: 'domcontentloaded' });
    expect(response?.status()).toBeLessThan(500);

    await waitForAppReady(page);

    const crashErrors = errors.filter((e) =>
      /is not defined|ReferenceError|TypeError.*undefined/i.test(e),
    );
    expect(crashErrors, `runtime errors: ${crashErrors.join('; ')}`).toEqual([]);
  });
});

test.describe('Admin feedback — authenticated', () => {
  test.skip(!authenticated, ADMIN_SESSION_REQUIRED);

  test('Triage tab renders 5 status columns', async ({ page }) => {
    await gotoAdmin(page, '/admin/feedback?tab=triage', HEADING);
    // role=tab, not role=button: these are Radix `TabsTrigger`s. The label
    // carries a live count ("Triage (12)"), hence the prefix match.
    await expect(page.getByRole('tab', { name: /^Triage/ })).toBeVisible({ timeout: 15_000 });
    for (const col of ['New', 'Under Review', 'Planned', 'In Progress', 'Done']) {
      await expect(page.getByText(new RegExp(`^${col}$`, 'i')).first()).toBeVisible();
    }
  });

  test('tab navigation reaches each tab without error', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err) => errors.push(err.message));
    await gotoAdmin(page, '/admin/feedback', HEADING);

    // All four tabs are rendered unconditionally by index.tsx, so a missing one
    // IS a regression — the previous `.catch(() => {})` swallowed exactly that.
    // It also cost the test its whole budget: clicking a locator that matches
    // nothing waits out the test timeout, which is why this used to die on
    // "Target page, context or browser has been closed" rather than on the
    // assertion. Click by role=tab and let a real absence fail here.
    for (const label of ['Stories', 'Triage', 'Roadmap', 'Analytics']) {
      const tab = page.getByRole('tab', { name: new RegExp(`^${label}`) });
      await expect(tab, `tab "${label}" is missing`).toBeVisible({ timeout: 15_000 });
      await tab.click({ timeout: 10_000 });
      await expect(tab).toHaveAttribute('data-state', 'active');
    }

    const crashErrors = errors.filter((e) => /is not defined|ReferenceError/i.test(e));
    expect(crashErrors, `tab nav errors: ${crashErrors.join('; ')}`).toEqual([]);
  });

  test('? opens the shortcut help overlay', async ({ page }) => {
    await gotoAdmin(page, '/admin/feedback', HEADING);
    await page.keyboard.press('Shift+Slash'); // '?'
    await expect(page.getByText(/Keyboard shortcuts/i).first()).toBeVisible({ timeout: 5_000 });
    await expect(page.getByText(/Copy prompt \+ record Claude handoff/i)).toBeVisible();
  });

  test('cmd+k opens the command palette', async ({ page }) => {
    await gotoAdmin(page, '/admin/feedback', HEADING);
    const mod = process.platform === 'darwin' ? 'Meta' : 'Control';
    await page.keyboard.press(`${mod}+k`);
    await expect(page.getByPlaceholder(/Type a command/i)).toBeVisible({ timeout: 5_000 });
  });

  test('the filters popover exposes the category, status, priority and assignee controls', async ({
    page,
  }) => {
    // `?tab=triage` is load-bearing: the default tab is 'stories'
    // (useFeedbackUrlState defaults) and FeedbackFilters only mounts on triage,
    // so this assertion could never have held on a bare /admin/feedback.
    await gotoAdmin(page, '/admin/feedback?tab=triage', HEADING);

    // Visible at rest: the search box and the Filters trigger.
    await expect(page.getByPlaceholder(/Search title, description, URL/i)).toBeVisible({
      timeout: 15_000,
    });
    const filters = page.getByRole('button', { name: /^Filters/ });
    await expect(filters).toBeVisible();

    // The controls themselves live inside a CLOSED Popover, and the option text
    // the old assertions looked for ("All priorities", "Any assignee") sits one
    // level deeper still, inside closed Radix Selects — so neither could ever be
    // visible on load. Open the popover and assert the real group labels.
    await filters.click();
    for (const group of ['Category', 'Status', 'Priority', 'Assignee']) {
      await expect(
        page.getByText(new RegExp(`^${group}$`)).first(),
        `filters popover is missing the ${group} control`,
      ).toBeVisible({ timeout: 10_000 });
    }
    // A "Has screenshot" control is NOT asserted: the string does not exist
    // anywhere in src/, so that third assertion was dead from the start.
  });

  test('URL state persists through reload', async ({ page }) => {
    // Same reason as above — the search input lives on the triage tab only.
    await gotoAdmin(page, '/admin/feedback?tab=triage&q=test&status=new', HEADING);
    const searchInput = page.getByPlaceholder(/Search title, description, URL/i);
    await expect(searchInput).toHaveValue(/test/i, { timeout: 15_000 });
    await page.reload();
    await expect(page.getByRole('heading', { name: HEADING, exact: true })).toBeVisible({
      timeout: 15_000,
    });
    await expect(searchInput).toHaveValue(/test/i, { timeout: 15_000 });
    expect(page.url()).toMatch(/q=test/);
    expect(page.url()).toMatch(/status=new/);
  });
});
