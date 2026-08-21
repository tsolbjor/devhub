// Signing in, once, and then proving the rest is silent.
//
// Every service on the platform delegates to the same Keycloak realm, so the
// second sign-in should never show a password field: the browser carries the
// realm's session cookie and the OIDC round trip completes without the user
// seeing it. That is the property worth testing, so these helpers assert it
// rather than re-typing the password per service.

const { expect } = require('@playwright/test');
const { credentials, realm, services } = require('./env');

// Does this element turn up within the timeout?
//
// Not locator.isVisible({ timeout }) — that option does nothing, the call
// answers from the current DOM and returns false for anything still loading.
// Every "the button was not there" bug in this suite came from that.
async function appears(locator, timeout = 15_000) {
  try {
    await locator.waitFor({ state: 'visible', timeout });
    return true;
  } catch {
    return false;
  }
}

// Keycloak's login form. The only place a password is typed.
async function fillKeycloakForm(page) {
  const username = page.locator('#username');
  await expect(username, 'Keycloak login form did not render').toBeVisible({ timeout: 30_000 });
  await username.fill(credentials.username);
  await page.locator('#password').fill(credentials.password);
  await page.locator('#kc-login, input[type="submit"]').first().click();
  await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
}

// True while the browser sits on a Keycloak page that is asking for something.
const onKeycloakLogin = (page) =>
  /\/realms\/[^/]+\/(login-actions|protocol\/openid-connect\/auth)/.test(page.url());

// Establish the realm session. Used by global-setup, which then saves the
// storage state every test reuses.
//
// The account console is a public SPA that bounces to Keycloak, so this waits
// for the password field to appear rather than for a URL: the login URL carries
// the account URL in its redirect_uri query, which makes URL matching here
// quietly match the wrong page and skip the login altogether.
async function keycloakLogin(page) {
  await page.goto(`${services.keycloak}/realms/${realm}/account/`, { waitUntil: 'domcontentloaded' });

  if (await appears(page.locator('#username'), 30_000)) {
    await fillKeycloakForm(page);
  }

  if (await page.locator('input[type="password"]:visible').count()) {
    throw new Error(`Keycloak did not accept ${credentials.username} (still at ${page.url()})`);
  }
}

// Services differ in how they start the flow: some redirect straight to
// Keycloak (the Homepage gateway policy), others show their own page with a
// "sign in with…" button. Click the button when it is there, then wait for the
// flow to land back on the service.
async function signIn(page, url, { button } = {}) {
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  if (button) {
    const trigger = page
      .getByRole('link', { name: button })
      .or(page.getByRole('button', { name: button }))
      .first();

    if (await appears(trigger)) {
      // The click starts a redirect chain (service → Keycloak → service), so
      // wait for the network to settle rather than for one navigation.
      await trigger.click();
      await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
    }
  }

  // Forgejo's OAuth consent screen, shown the first time Woodpecker asks for
  // access. Absent once granted.
  const authorize = page.getByRole('button', { name: /^authorize/i }).first();
  if (await appears(authorize, 5_000)) {
    await authorize.click();
    await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
  }

  // The realm session already exists, so being asked for a password here means
  // this client's OIDC configuration is broken — a wrong redirect URI, a client
  // secret that no longer matches, a missing groups scope. That is a finding,
  // not something to type through, so report where it stopped.
  expect(onKeycloakLogin(page), `${url} bounced back to the Keycloak login form — SSO is broken for this client`)
    .toBeFalsy();

  expect(
    await page.locator('input[type="password"]:visible').count(),
    `${url} still shows its own login form (at ${page.url()}) — the OIDC round trip did not complete`,
  ).toBe(0);
}

module.exports = { keycloakLogin, signIn, fillKeycloakForm, onKeycloakLogin, appears };
