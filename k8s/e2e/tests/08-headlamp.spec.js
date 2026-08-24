// Headlamp: never anonymous, and able to read the cluster with the curated
// read-only ServiceAccount.
//
// Headlamp runs *without* its own OIDC, deliberately: its OIDC mode forwards the
// user's token to the Kubernetes API server, and a managed cluster will not
// accept a token from a custom issuer (AKS trusts Entra only). So the Keycloak
// round trip happens at the gateway instead — the same SecurityPolicy pattern
// Homepage and Portal use — and cluster access is the headlamp-view token from
// `./deploy.sh --env <env> headlamp-token`. See
// k8s/base/devops/headlamp/values.yaml.
//
// The property worth testing is therefore *not* "an OIDC button is on the page".
// It is: the gateway refuses anonymous requests, and the token that ships with
// the platform grants exactly read-only access.

const { test, expect } = require('@playwright/test');
const { services, headlampToken } = require('../lib/env');
const { onKeycloakLogin } = require('../lib/sso');

test.describe('headlamp', () => {
  test('is not served anonymously', async ({ browser }) => {
    // A context with no storage state — no realm session, so the gateway's
    // SecurityPolicy has nothing to accept and must send us to Keycloak.
    const anon = await browser.newContext({ ignoreHTTPSErrors: true, storageState: undefined });
    const page = await anon.newPage();
    try {
      await page.goto(services.headlamp, { waitUntil: 'domcontentloaded' });
      await page.waitForLoadState('networkidle').catch(() => {});

      expect(
        onKeycloakLogin(page) || (await page.locator('input[type="password"]:visible').count()) > 0,
        `${services.headlamp} served a page to an unauthenticated browser (landed at ${page.url()}) ` +
          '— the gateway OIDC SecurityPolicy is not in effect',
      ).toBeTruthy();
    } finally {
      await anon.close();
    }
  });

  test('the signed-in user reaches Headlamp itself', async ({ page }) => {
    // The realm session already exists, so the gateway round trip is silent and
    // Headlamp's own UI is what renders.
    await page.goto(services.headlamp, { waitUntil: 'domcontentloaded' });
    await page.waitForLoadState('networkidle').catch(() => {});

    expect(
      onKeycloakLogin(page),
      `${services.headlamp} bounced back to the Keycloak login form — gateway SSO is broken for this client`,
    ).toBeFalsy();

    await expect(page.locator('body')).toContainText(/headlamp|cluster|token/i, { timeout: 30_000 });
  });

  test('lists cluster nodes with the read-only token', async ({ page }) => {
    test.skip(
      !headlampToken,
      'DEVHUB_HEADLAMP_TOKEN is not set — run through validate-e2e.sh to test cluster access',
    );

    await page.goto(services.headlamp, { waitUntil: 'domcontentloaded' });
    await page.waitForLoadState('networkidle').catch(() => {});

    // The token screen is the expected state here, not a failure: it is how a
    // human authenticates to the API with the headlamp-view ServiceAccount.
    const tokenField = page.locator('input[type="password"], textarea, input#token').first();
    if (await tokenField.isVisible().catch(() => false)) {
      await tokenField.fill(headlampToken);
      await page
        .getByRole('button', { name: /authenticate|sign in|submit|continue/i })
        .first()
        .click();
      await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
    }

    await page.goto(`${services.headlamp}/c/main/nodes`, { waitUntil: 'domcontentloaded' });

    // The node name differs per cloud, so assert on the table having rows and
    // on the absence of the two texts Headlamp shows when RBAC is wrong.
    await expect(page.locator('body')).not.toContainText(/error loading|forbidden/i, { timeout: 60_000 });
    await expect(page.locator('table tbody tr, [role="row"]').first()).toBeVisible({ timeout: 90_000 });
  });
});
