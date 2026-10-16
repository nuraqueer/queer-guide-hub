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

/** The six real top-level tabs (`TABS` in UnifiedDataOps.tsx). */
const TOP_LEVEL_TABS = ['Overview', 'Builder', 'Monitoring', 'Sources', 'News', 'Audit'];

async function waitForAppReady(page: Page) {
  await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {
    /* ignore */
  });
}

/**
 * The Builder opens a modal first-run tour ("Welcome to the Pipeline Builder")
 * gated on localStorage `pipeline-builder-tour-seen-v1`. Every Playwright
 * context is a fresh profile, so it fires on EVERY run — and it is a focus-
 * trapping dialog, which is why the toolbar was unreachable and both keyboard
 * tests (⌘K, ?) were swallowed. Dismiss it before touching the builder.
 *
 * Tolerant by design: a session that has already seen the tour never shows it,
 * so its absence is not a failure. Everything after this call is asserted
 * strictly, so a tour that stopped being dismissable still fails loudly there.
 */
async function dismissBuilderTour(page: Page) {
  const tour = page.getByRole('dialog', { name: /Welcome to the Pipeline Builder/i });
  if (await tour.isVisible().catch(() => false)) {
    await page.getByRole('button', { name: /Skip tour/i }).click();
    await expect(tour).toBeHidden({ timeout: 10_000 });
  }
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
    // role=tab, not role=button: UnifiedDataOps renders `<button role="tab">`,
    // and an explicit ARIA role wins, so getByRole('button') matched nothing.
    await expect(page.getByRole('tab', { name: 'Overview' })).toBeVisible({ timeout: 15_000 });
    await expect(page.getByText(/Active definitions/i)).toBeVisible();
    await expect(page.getByText(/Runs in last 24h/i)).toBeVisible();
    await expect(page.getByRole('columnheader', { name: /Kind/i })).toBeVisible();
  });

  test('tab navigation reaches each of the six tabs without error', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err) => errors.push(err.message));
    await gotoAdmin(page, '/admin/pipelines', HEADING);

    // The old list named twelve tabs. Eight of them (Monitor, Review, DLQ,
    // Errors, Alerts, Coverage, Health, Integrations) are no longer top-level:
    // the console was consolidated to six, and those live on as SUB-SECTIONS
    // reached through TAB_ALIAS deep links — which is why the ?tab=monitor,
    // ?tab=audit and ?tab=integrations tests below kept working. Asserting them
    // as top-level tabs could only ever fail.
    await expect(page.getByRole('tablist', { name: /Data ops sections/i })).toBeVisible();
    for (const label of TOP_LEVEL_TABS) {
      const tab = page.getByRole('tab', { name: label });
      await expect(tab, `top-level tab "${label}" is missing`).toBeVisible({ timeout: 15_000 });
      await tab.click({ timeout: 10_000 });
      await expect(tab).toHaveAttribute('aria-selected', 'true');
      if (label === 'Builder') await dismissBuilderTour(page);
    }

    const crashErrors = errors.filter((e) => /is not defined|ReferenceError/i.test(e));
    expect(crashErrors, `tab navigation errors: ${crashErrors.join('; ')}`).toEqual([]);
  });

  test('Builder toolbar shows Save, Run, Dry Run buttons', async ({ page }) => {
    await gotoAdmin(page, '/admin/pipelines?tab=builder', HEADING);
    await dismissBuilderTour(page);
    await expect(page.getByRole('button', { name: /^Save$/ })).toBeVisible({ timeout: 15_000 });
    await expect(page.getByRole('button', { name: /^Run$/ })).toBeVisible();
    await expect(page.getByRole('button', { name: /^Dry Run$/ })).toBeVisible();
  });

  test('Keyboard shortcut ⌘K opens quick-add palette', async ({ page }) => {
    await gotoAdmin(page, '/admin/pipelines?tab=builder', HEADING);
    await dismissBuilderTour(page);
    // Wait for the builder itself, not a bare timeout: the shortcut is bound by
    // PipelineBuilder, so pressing it before the lazy chunk mounts does nothing.
    await expect(page.getByRole('button', { name: /^Save$/ })).toBeVisible({ timeout: 15_000 });
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
    await dismissBuilderTour(page);
    await expect(page.getByRole('button', { name: /^Save$/ })).toBeVisible({ timeout: 15_000 });
    await page.keyboard.press('Shift+Slash');
    await expect(page.getByRole('dialog', { name: /Keyboard Shortcuts/i })).toBeVisible({
      timeout: 5_000,
    });
  });
});
