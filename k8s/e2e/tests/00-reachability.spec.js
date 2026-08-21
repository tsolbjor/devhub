// Is anything answering at all?
//
// Runs first so that a platform which is simply not up fails here with a list
// of hostnames, instead of every later test timing out on its own.

const { test, expect } = require('@playwright/test');
const { services, ENV } = require('../lib/env');

test.describe('reachability', () => {
  for (const [name, url] of Object.entries(services)) {
    test(`${name} answers on ${url}`, async ({ browser }) => {
      // A context with no storage state: this is the anonymous view, and it
      // must not depend on the sign-in the rest of the suite shares.
      const context = await browser.newContext({ ignoreHTTPSErrors: true, storageState: undefined });
      const page = await context.newPage();
      try {
        const res = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60_000 });
        const status = res ? res.status() : 0;

        // Chromium follows the redirect chain, so what lands here is the final
        // page: the service itself, or a Keycloak login form. Both mean the
        // Gateway has a backend for this hostname. 404 and 5xx do not.
        expect(status, `${name} → ${page.url()} returned ${status}`).toBeLessThan(400);
      } finally {
        await context.close();
      }
    });
  }

  // cert-manager issues one certificate per gateway listener, so a hostname
  // added without a listener gets served the wrong certificate and fails here
  // while still passing the reachability test above.
  test('TLS certificates are trusted', async ({ browser }) => {
    test.skip(ENV === 'local', 'local terminates with its own CA — trusting it is a workstation concern');

    const context = await browser.newContext({ ignoreHTTPSErrors: false, storageState: undefined });
    const page = await context.newPage();
    try {
      for (const [name, url] of Object.entries(services)) {
        const res = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60_000 }).catch((e) => {
          throw new Error(`${name} failed TLS verification: ${e.message}`);
        });
        expect(res.status(), `${name} returned ${res.status()}`).toBeLessThan(500);
      }
    } finally {
      await context.close();
    }
  });

  test('no service is serving an unrendered ${VAR}', async ({ browser }) => {
    const context = await browser.newContext({ ignoreHTTPSErrors: true, storageState: undefined });
    const page = await context.newPage();
    try {
      // The gateway is the one place every hostname passes through, so a
      // placeholder that survived Helm templating shows up as a literal
      // "${DOMAIN}" in a redirect target or a rendered page.
      for (const [name, url] of Object.entries(services)) {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60_000 });
        expect(page.url(), `${name} redirected to a URL containing a placeholder`).not.toContain('${');
      }
    } finally {
      await context.close();
    }
  });
});
