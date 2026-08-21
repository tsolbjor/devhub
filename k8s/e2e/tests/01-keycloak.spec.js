// Keycloak: the realm exists, and it is the realm everything else points at.
//
// This is the check that would have caught the platform's worst silent failure:
// recreating the data-services PostgreSQL leaves Keycloak running with an empty
// schema, so /realms/devops 404s and every service's login redirect dead-ends
// on "We are sorry… Page not found".

const { test, expect } = require('@playwright/test');
const { services, realm, credentials } = require('../lib/env');
const { apiJson } = require('../lib/http');

test.describe('keycloak', () => {
  test(`realm ${realm} is published`, async ({ page }) => {
    const res = await apiJson(page, `${services.keycloak}/realms/${realm}/.well-known/openid-configuration`);
    expect(res.status, `realm '${realm}' does not exist — run ./devhub keycloak --env <env>`).toBe(200);

    const cfg = res.json;
    expect(cfg.issuer).toContain(`/realms/${realm}`);
    // Browser-facing endpoints must be the public hostname; an in-cluster
    // service URL here would send every redirect somewhere unroutable.
    expect(cfg.authorization_endpoint).toContain(services.keycloak);
    expect(cfg.grant_types_supported).toContain('authorization_code');
  });

  test('the platform admin has a working session', async ({ page }) => {
    await page.goto(`${services.keycloak}/realms/${realm}/account/`, { waitUntil: 'domcontentloaded' });
    await page.waitForLoadState('networkidle').catch(() => {});

    // Reached with the storage state from global-setup, so the console must
    // render rather than bounce to a password prompt. Asserting on the absence
    // of the form rather than on console text keeps this independent of
    // Keycloak's UI copy, which changes between versions.
    expect(
      await page.locator('input[type="password"]:visible').count(),
      `the account console asked ${credentials.username} to sign in again`,
    ).toBe(0);
    expect(page.url()).toContain(`/realms/${realm}/account`);
  });
});
