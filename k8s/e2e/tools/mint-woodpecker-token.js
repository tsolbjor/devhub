// Mint a Woodpecker personal API token by walking the same SSO chain a human
// does — Keycloak → Forgejo → Woodpecker — in a headless browser, then asking
// Woodpecker's own token endpoint. Woodpecker only mints user tokens for a
// signed-in session (there is no CLI or admin API for it), which used to make
// `ci-secrets` the platform's one manual step. This removes the human.
//
// Run through k8s/scripts/mint-woodpecker-token.sh, which exports the same
// DEVHUB_* variables validate-e2e.sh uses. Prints exactly one line to stdout:
// the token. Everything else goes to stderr.
//
// The user must be in WOODPECKER_ADMIN (org secrets need admin) — platform-admin
// is, per k8s/base/devops/woodpecker/values.yaml.

'use strict';

const { chromium } = require('@playwright/test');
const { services, credentials, realm } = require('../lib/env');

const log = (msg) => process.stderr.write(`[mint-token] ${msg}\n`);

async function appears(locator, timeout) {
  try {
    await locator.waitFor({ state: 'visible', timeout });
    return true;
  } catch {
    return false;
  }
}

(async () => {
  if (!credentials.password) throw new Error('DEVHUB_ADMIN_PASSWORD is not set');

  const browser = await chromium.launch();
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await context.newPage();
  page.setDefaultTimeout(30_000);

  try {
    // 1. Keycloak realm session.
    log(`Keycloak sign-in as ${credentials.username}…`);
    await page.goto(`${services.keycloak}/realms/${realm}/account/`, { waitUntil: 'domcontentloaded' });
    if (await appears(page.locator('#username'), 30_000)) {
      await page.locator('#username').fill(credentials.username);
      await page.locator('#password').fill(credentials.password);
      await page.locator('#kc-login, input[type="submit"]').first().click();
      await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
    }
    if (await page.locator('input[type="password"]:visible').count()) {
      throw new Error(`Keycloak did not accept ${credentials.username} (at ${page.url()})`);
    }

    // 2. Forgejo session via its OpenID Connect auth source (silent — the
    // realm session exists). The login page's SSO link href always contains
    // /user/oauth2/, whatever the auth source is called.
    log('Forgejo sign-in…');
    await page.goto(`${services.forgejo}/user/login`, { waitUntil: 'domcontentloaded' });
    const sso = page.locator('a[href*="/user/oauth2/"]').first();
    if (await appears(sso, 10_000)) {
      await sso.click();
      await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
    }

    // 3. Woodpecker via Forgejo's OAuth app; first time shows a consent page.
    log('Woodpecker sign-in…');
    await page.goto(services.woodpecker, { waitUntil: 'domcontentloaded' });
    // The login page's forge button is labeled with the forge's hostname
    // ("Sign in to Woodpecker with <git host>"), not "login".
    const gitHost = new URL(services.forgejo).host.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const loginName = new RegExp(`login with|sign in with|^log ?in$|${gitHost}`, 'i');
    const login = page
      .getByRole('link', { name: loginName })
      .or(page.getByRole('button', { name: loginName }))
      .first();
    if (await appears(login, 10_000)) {
      await login.click();
      await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
    }
    const authorize = page.getByRole('button', { name: /^authorize/i }).first();
    if (await appears(authorize, 5_000)) {
      await authorize.click();
      await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
    }

    // 4. The token, from Woodpecker's own endpoint, with its CSRF token —
    // exactly what the UI's "API token" page does.
    log('Requesting personal token…');
    if (new URL(page.url()).origin !== new URL(services.woodpecker).origin) {
      await page.goto(services.woodpecker, { waitUntil: 'domcontentloaded' });
    }
    const token = await page.evaluate(async () => {
      const cfg = await fetch('/web-config.js', { credentials: 'include' }).then((r) => r.text());
      const csrf = (cfg.match(/WOODPECKER_CSRF\s*=\s*"([^"]+)"/) || [])[1] || '';
      const res = await fetch('/api/user/token', {
        method: 'POST',
        headers: csrf ? { 'X-CSRF-TOKEN': csrf } : {},
        credentials: 'include',
      });
      if (!res.ok) throw new Error(`POST /api/user/token: ${res.status} ${await res.text()}`);
      return (await res.text()).trim().replace(/^"|"$/g, '');
    });
    if (!token) throw new Error('Woodpecker returned an empty token');

    log('Token minted.');
    process.stdout.write(`${token}\n`);
    await browser.close();
  } catch (err) {
    await page.screenshot({ path: 'mint-woodpecker-token-failed.png' }).catch(() => {});
    await browser.close().catch(() => {});
    throw err;
  }
})().catch((err) => {
  log(`FAILED: ${err.message}`);
  process.exit(1);
});
