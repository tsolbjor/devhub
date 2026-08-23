// Portal: the developer wizard. Like Homepage its authentication is the
// gateway's OIDC SecurityPolicy, and unlike Homepage it holds a Forgejo token
// that can create repositories — so the anonymous check here is not hygiene,
// it is what keeps repo creation behind SSO.
//
// Read-only on purpose: the suite asserts the wizard is served and wired, and
// never submits it. A test that scaffolds a repository per run would litter
// the org and trigger forgejo-appset deployments.

const { test, expect } = require('@playwright/test');
const { services } = require('../lib/env');
const { signIn } = require('../lib/sso');

test.describe('portal', () => {
  test('anonymous requests are sent to Keycloak, not served', async ({ browser }) => {
    const context = await browser.newContext({ ignoreHTTPSErrors: true, storageState: undefined });
    const page = await context.newPage();
    try {
      await page.goto(services.portal, { waitUntil: 'domcontentloaded', timeout: 60_000 });
      expect(page.url(), 'the gateway served the wizard without authenticating').toContain(
        '/protocol/openid-connect/auth',
      );
    } finally {
      await context.close();
    }
  });

  test('renders the wizard once signed in', async ({ page }) => {
    await signIn(page, services.portal);

    // The form itself: name field, template picker, submit.
    await expect(page.locator('#name')).toBeVisible({ timeout: 60_000 });
    await expect(page.locator('#submit')).toBeVisible();

    // The template <select> is filled from /api/config, which the backend
    // answers after asking Forgejo — so one option existing means the pod is
    // up, the ConfigMap mounted, and the in-cluster Forgejo URL reachable.
    // (An unreachable Forgejo still yields the built-in default option, which
    // is why this asserts ≥ 1 rather than a specific template.)
    await expect(page.locator('#template option')).not.toHaveCount(0, { timeout: 30_000 });

    // A literal ${DOMAIN} anywhere is the values-rendering bug.
    await expect(page.locator('body')).not.toContainText('${');
  });

  test('name validation rejects platform hostnames and accepts free names', async ({ page }) => {
    await signIn(page, services.portal);
    await expect(page.locator('#name')).toBeVisible({ timeout: 60_000 });

    // Through the page's own fetch: same gateway session, and *.localhost
    // resolves in Chromium where Node's getaddrinfo fails.
    const check = (name) =>
      page.evaluate(
        (n) => fetch('/api/validate-name?name=' + encodeURIComponent(n)).then((r) => r.json()),
        name,
      );

    // "grafana.<domain>" is the platform's own hostname — never an app.
    expect((await check('grafana')).available).toBe(false);
    // Not a DNS label.
    expect((await check('Bad_Name')).available).toBe(false);
    // Read-only: validated, never created.
    expect((await check('e2e-name-probe')).available).toBe(true);
  });
});
