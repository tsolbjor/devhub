// One sign-in for the whole run.
//
// Logging in per test file would test Keycloak's login form nine times and the
// platform's SSO once. Signing in here and handing every test the resulting
// storage state inverts that: each service then has to complete the OIDC flow
// silently, which is what a user actually experiences.

const { chromium } = require('@playwright/test');
const path = require('path');
const { keycloakLogin } = require('./lib/sso');
const { credentials } = require('./lib/env');

module.exports = async () => {
  if (!credentials.password) {
    throw new Error(
      'DEVHUB_ADMIN_PASSWORD is not set — validate-e2e.sh reads it from ' +
        'k8s/scripts/<env>/oidc-secrets.env, which setup-keycloak.sh writes',
    );
  }

  const browser = await chromium.launch();
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await context.newPage();

  try {
    await keycloakLogin(page);

    const state = await context.storageState({ path: path.join(__dirname, '.auth', 'state.json') });

    // An empty cookie jar means the login silently did not happen, and every
    // test would then fail with its own confusing symptom. Fail here instead.
    if (!state.cookies.length) {
      throw new Error('Signed in but Keycloak set no cookies — the realm session was not established');
    }
  } finally {
    await browser.close();
  }
};
