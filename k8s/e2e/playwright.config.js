// End-to-end validation of a live devhub environment.
//
// Run through k8s/scripts/validate-e2e.sh (./devhub validate --e2e --env <env>),
// which resolves the domain from the overlay's config.yaml and the admin
// password from the generated oidc-secrets.env.
//
// Read-only by design: every test signs in, looks, and asserts. Nothing here
// creates a repository, triggers a pipeline or writes a secret, so it is safe
// against a production platform.

const { defineConfig } = require('@playwright/test');
const path = require('path');
const { ENV } = require('./lib/env');

// Local runs terminate TLS with the environment's own CA, which the browser has
// no reason to trust. Certificate *validity* is asserted separately in
// tls.spec.js, where a failure can say so plainly instead of every test dying
// at the first navigation.
const isLocal = ENV === 'local';

module.exports = defineConfig({
  testDir: path.join(__dirname, 'tests'),
  globalSetup: require.resolve('./global-setup.js'),

  // Services share one Keycloak. Running files in parallel means several
  // simultaneous OIDC flows against the same realm session, which is a
  // different thing to test than the one this suite is for.
  workers: 1,
  fullyParallel: false,

  // A platform that has just been deployed is still pulling images and warming
  // caches; a first page load taking half a minute is normal and not a failure.
  timeout: 120_000,
  expect: { timeout: 30_000 },

  // No retries: a flake here is a finding. Re-running the command is cheap and
  // an intermittent pass is exactly the signal that should not be hidden.
  retries: 0,

  reporter: process.env.CI
    ? [['list'], ['html', { outputFolder: path.join(__dirname, 'report'), open: 'never' }]]
    : [['list'], ['html', { outputFolder: path.join(__dirname, 'report'), open: 'never' }]],

  outputDir: path.join(__dirname, 'results'),

  use: {
    ignoreHTTPSErrors: true,
    storageState: path.join(__dirname, '.auth', 'state.json'),
    actionTimeout: 30_000,
    navigationTimeout: 60_000,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    video: 'off',
    // Chromium resolves *.localhost itself, so a local run needs no hosts file
    // and no DNS. Cloud environments resolve through external-dns as usual.
    baseURL: undefined,
  },

  metadata: { environment: ENV, tlsTrusted: !isLocal },
});
