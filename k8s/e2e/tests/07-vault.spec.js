// Vault: initialised, unsealed, and serving its UI.
//
// Seal state needs no credential, which makes it the one check here that works
// when everything else is broken — and a sealed Vault is the fastest way to
// take the platform down, because External Secrets stops delivering and every
// restarted pod comes back without its secrets.

const { test, expect } = require('@playwright/test');
const { services } = require('../lib/env');
const { signIn } = require('../lib/sso');
const { apiJson } = require('../lib/http');

test.describe('vault', () => {
  test('is initialised and unsealed', async ({ page }) => {
    const res = await apiJson(page, `${services.vault}/v1/sys/seal-status`);
    expect(res.status, `seal-status → ${res.status}`).toBe(200);

    expect(res.json.initialized, 'Vault is not initialised — run ./devhub vault --env <env>').toBeTruthy();
    expect(res.json.sealed, 'Vault is SEALED — External Secrets cannot deliver anything').toBeFalsy();
  });

  test('reports itself active and unsealed', async ({ page }) => {
    // 200 = initialised, unsealed, active. Every other code is a distinct
    // degraded state (429 standby, 501 uninitialised, 503 sealed), so assert
    // the exact one and let the number say which.
    const res = await apiJson(page, `${services.vault}/v1/sys/health`);
    expect(res.status, `sys/health returned ${res.status} — not the active, unsealed node`).toBe(200);
  });

  // Vault is deliberately not signed in here. Unlike the other services it
  // holds the platform's secrets and is reached with a token rather than the
  // shared browser session, so this asserts that the UI is served and its API
  // is answering — not that a session exists.
  //
  // The enabled auth methods are not asserted: Vault only lists them to an
  // authenticated caller, and listing them anonymously would be the finding.
  test('serves the UI', async ({ page }) => {
    await page.goto(`${services.vault}/ui/`, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('body')).toContainText(/vault|sign in/i, { timeout: 60_000 });

    const mounts = await apiJson(page, `${services.vault}/v1/sys/internal/ui/mounts`);
    expect(mounts.status, 'the UI API is not answering').toBe(200);
  });
});
