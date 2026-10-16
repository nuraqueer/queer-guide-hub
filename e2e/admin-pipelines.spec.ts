import { test, expect, type Page } from '@playwright/test';
import { authenticated, ADMIN_SESSION_REQUIRED, gotoAdmin } from './support/adminAuth';

/**
 * E2E smoke tests for /admin/pipelines.
 * Unauthenticated tests verify the app shell loads without crashes.
 * Authenticated tests cover tab navigation, builder interactions, and the
 * audit / integrations / monitor features.
 *
 * Gating moved off `E2E_ADMIN_COOKIE` (which nothing has ever set, so all eight
 * authenticated tests had never run anywhere) onto the storageState session the
 * config already attaches. See e2e/support/adminAuth.ts.
 */

const HEADING = 'Pipelines';

async function waitForAppReady(page: Page) {
  await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {
    /* ignore */
  });
}

test.describe('Admin pipelines — unauthenticated', () => {
  test('reaches /admin/pipelines without runtime crash', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err) => errors.push(err.message));

    const response = await page.goto('/admin/pipelines', { waitUntil: 'domcontentloaded' });
    expect(response?.status()).toBeLessThan(500);

    await waitForAppReady(page);

    const crashErrors = errors.filter((e) =>
      /is not defined|ReferenceError|TypeError.*undefined/i.test(e),
    );
    expect(crashErrors, `runtime errors: ${crashErrors.join('; ')}`).toEqual([]);
  });
});

test.describe('Admin pipelines — authenticated', () => {
  test.skip(!authenticated, ADMIN_SESSION_REQUIRED);

  test('Overview tab renders with summary cards and table', async ({ page }) => {
    await gotoAdmin(page, '/admin/pipelines', HEADING);
    await expect(page.getByRole('button', { name: /Overview/i })).toBeVisible({ timeout: 15_000 });
    await expect(page.getByText(/Active definitions/i)).toBeVisible();
    await expect(page.getByText(/Runs in last 24h/i)).toBeVisible();
    await expect(page.getByRole('columnheader', { name: /Kind/i })).toBeVisible();
  });

  test('tab navigation reaches each tab without error', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err) => errors.push(err.message));
    await gotoAdmin(page, '/admin/pipelines', HEADING);

    const tabs = [
      'Builder',
      'Monitor',
      'Sources',
      'Review',
      'DLQ',
      'Errors',
      'Alerts',
      'Coverage',
      'News',
      'Health',
      'Audit',
      'Integrations',
    ];
    for (const label of tabs) {
      await page
        .getByRole('button', { name: new RegExp(`^${label}$`, 'i') })
        .first()
        .click();
      await page.waitForTimeout(500);
    }

    const crashErrors = errors.filter((e) => /is not defined|ReferenceError/i.test(e));
    expect(crashErrors, `tab navigation errors: ${crashErrors.join('; ')}`).toEqual([]);
  });

  test('Builder toolbar shows Save, Run, Dry Run buttons', async ({ page }) => {
    await gotoAdmin(page, '/admin/pipelines?tab=builder', HEADING);
    await expect(page.getByRole('button', { name: /Save$/i })).toBeVisible({ timeout: 10_000 });
    await expect(page.getByRole('button', { name: /Run$/i })).toBeVisible();
    await expect(page.getByRole('button', { name: /Dry Run/i })).toBeVisible();
  });

  test('Keyboard shortcut ⌘K opens quick-add palette', async ({ page }) => {
    await gotoAdmin(page, '/admin/pipelines?tab=builder', HEADING);
    const isMac = await page.evaluate(() => navigator.platform.includes('Mac'));
    await page.keyboard.press(isMac ? 'Meta+k' : 'Control+k');

    // Quick-add palette should show a search placeholder
    await expect(page.getByPlaceholder(/Type to search nodes/i)).toBeVisible({ timeout: 5_000 });
  });

  test('Audit tab shows event timeline', async ({ page }) => {
    await gotoAdmin(page, '/admin/pipelines?tab=audit', HEADING);
    await expect(page.getByText(/Audit Trail/i)).toBeVisible({ timeout: 10_000 });
    // Filter chips
    await expect(page.getByRole('button', { name: /^save$/i })).toBeVisible();
    await expect(page.getByRole('button', { name: /^run$/i })).toBeVisible();
  });

  test('Integrations tab allows adding a webhook', async ({ page }) => {
    await gotoAdmin(page, '/admin/pipelines?tab=integrations', HEADING);
    await expect(page.getByText(/Alert Webhook Integrations/i)).toBeVisible({ timeout: 10_000 });

    await page.getByRole('button', { name: /Add integration/i }).click();
    await expect(page.getByText(/New webhook integration/i)).toBeVisible();
    await expect(page.getByPlaceholder(/#data-ops alerts/i)).toBeVisible();
    // Don't actually submit; just verify form renders
    await page.keyboard.press('Escape');
  });

  test('Monitor tab shows charts', async ({ page }) => {
    await gotoAdmin(page, '/admin/pipelines?tab=monitor', HEADING);
    await expect(page.getByText(/Run duration distribution/i)).toBeVisible({ timeout: 10_000 });
    await expect(page.getByText(/Throughput \(last 24h\)/i)).toBeVisible();
    await expect(page.getByRole('button', { name: /Compare runs/i })).toBeVisible();
  });

  test('Help cheat sheet opens with ? key', async ({ page }) => {
    await gotoAdmin(page, '/admin/pipelines?tab=builder', HEADING);
    await page.keyboard.press('Shift+Slash');
    await expect(page.getByText(/Keyboard Shortcuts/i).first()).toBeVisible({ timeout: 5_000 });
  });
});
