// Headlamp: reachable, offering Keycloak sign-in, and able to read the cluster.
//
// Headlamp falls back to "paste a service account token" whenever its OIDC
// configuration is missing — a fallback that looks like a working page and is
// unusable for everyone who does not have a token to paste. That fallback is
// the specific thing this test refuses to accept.

const { test, expect } = require('@playwright/test');
const { services } = require('../lib/env');
const { signIn, appears } = require('../lib/sso');

test.describe('headlamp', () => {
  test('offers Keycloak sign-in rather than a token prompt', async ({ page }) => {
    await page.goto(services.headlamp, { waitUntil: 'domcontentloaded' });
    await page.waitForLoadState('networkidle').catch(() => {});

    const tokenPrompt = page.getByText(/paste your authentication token/i).first();
    const oidcButton = page.getByRole('button', { name: /sign in|keycloak|oidc/i }).first();

    if (await appears(tokenPrompt, 10_000)) {
      throw new Error(
        'Headlamp is asking for a service-account token — its OIDC configuration ' +
          'is not in effect (check the headlamp-oidc-secret wiring in the deployed release)',
      );
    }

    expect(await appears(oidcButton, 15_000), 'no sign-in control on the Headlamp page').toBeTruthy();
  });

  test('signs in and lists cluster nodes', async ({ page }) => {
    await signIn(page, services.headlamp, { button: /sign in|keycloak|oidc/i });

    // A SPA: it renders the cluster view after its first API call returns, so
    // wait for content rather than for a URL.
    await expect(page.locator('body')).toContainText(/cluster|nodes|namespaces|workloads/i, { timeout: 90_000 });

    await page.goto(`${services.headlamp}/c/main/nodes`, { waitUntil: 'domcontentloaded' });

    // The node name differs per cloud, so assert on the table having rows and
    // on the absence of the two texts Headlamp shows when RBAC is wrong.
    await expect(page.locator('body')).not.toContainText(/error loading|forbidden/i, { timeout: 60_000 });
    await expect(page.locator('table tbody tr, [role="row"]').first()).toBeVisible({ timeout: 90_000 });
  });
});
