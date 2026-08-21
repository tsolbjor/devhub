// Homepage: the front door, and the one service whose authentication is not its
// own — Envoy Gateway runs the OIDC flow in front of it via a SecurityPolicy.
//
// Two distinct failures live here, and both have happened: the gateway policy
// pointing at a realm that does not exist (endless redirect to a 404), and the
// pod rejecting the request itself because HOMEPAGE_ALLOWED_HOSTS never had
// ${DOMAIN} substituted ("Host validation failed").

const { test, expect } = require('@playwright/test');
const { services } = require('../lib/env');
const { signIn } = require('../lib/sso');

test.describe('homepage', () => {
  test('anonymous requests are sent to Keycloak, not served', async ({ browser }) => {
    // No storage state: this is what someone who found the hostname would get.
    // Homepage has no authentication of its own, so if the gateway's
    // SecurityPolicy is not intercepting, the platform's entire service index
    // is public.
    const context = await browser.newContext({ ignoreHTTPSErrors: true, storageState: undefined });
    const page = await context.newPage();
    try {
      await page.goto(services.homepage, { waitUntil: 'domcontentloaded', timeout: 60_000 });
      expect(page.url(), 'the gateway served the page without authenticating').toContain(
        '/protocol/openid-connect/auth',
      );
    } finally {
      await context.close();
    }
  });

  test('renders the platform index once signed in', async ({ page }) => {
    await signIn(page, services.homepage);

    // Homepage answers with its own error text rather than a status code when
    // the Host header is not allow-listed, so assert on the body.
    await expect(page.locator('body')).not.toContainText(/host validation failed/i);

    // The tiles are links to the other services; at least the ones this suite
    // also tests should be on the page.
    const links = page.locator('a[href^="http"]');
    await expect(links.first()).toBeVisible({ timeout: 60_000 });

    const hrefs = await links.evaluateAll((els) => els.map((e) => e.getAttribute('href')));
    for (const expected of [services.grafana, services.argocd, services.forgejo]) {
      expect(hrefs.some((h) => h && h.startsWith(expected)), `no tile links to ${expected}`).toBeTruthy();
    }

    // A tile pointing at a literal ${DOMAIN} is the values-rendering bug in its
    // most visible form.
    expect(hrefs.join(' ')).not.toContain('${');
  });
});
