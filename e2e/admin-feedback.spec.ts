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
    await expect(page.getByRole('button', { name: /Triage/i })).toBeVisible({
      timeout: 15_000,
    });
    for (const col of ['New', 'Under Review', 'Planned', 'In Progress', 'Done']) {
      await expect(page.getByText(new RegExp(`^${col}$`, 'i')).first()).toBeVisible();
    }
  });

  test('tab navigation reaches each tab without error', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err) => errors.push(err.message));
    await gotoAdmin(page, '/admin/feedback', HEADING);

    for (const label of ['Stories', 'Triage', 'Analytics', 'Roadmap']) {
      await page
        .getByRole('button', { name: new RegExp(`^${label}`, 'i') })
        .first()
        .click()
        .catch(() => {
          /* tab may be hidden if no data */
        });
      await page.waitForTimeout(400);
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

  test('filters row shows priority, assignee, has-screenshot controls', async ({ page }) => {
    await gotoAdmin(page, '/admin/feedback', HEADING);
    await expect(page.getByText(/All priorities/i).first()).toBeVisible({ timeout: 10_000 });
    await expect(page.getByText(/Any assignee/i).first()).toBeVisible();
    await expect(page.getByText(/Has screenshot/i).first()).toBeVisible();
  });

  test('URL state persists through reload', async ({ page }) => {
    await gotoAdmin(page, '/admin/feedback?q=test&status=new', HEADING);
    const searchInput = page.getByPlaceholder(/Search/i).first();
    await expect(searchInput).toHaveValue(/test/i, { timeout: 10_000 });
    await page.reload();
    await expect(page.getByRole('heading', { name: HEADING, exact: true })).toBeVisible({
      timeout: 15_000,
    });
    expect(page.url()).toMatch(/q=test/);
    expect(page.url()).toMatch(/status=new/);
  });
});
