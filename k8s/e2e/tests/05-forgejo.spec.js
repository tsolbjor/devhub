// Forgejo: SSO through Keycloak, and the environment's own GitOps repository
// present and browsable.
//
// Forgejo is where the platform's source of truth lives after handover, so
// "logs in" is not enough — the repository ArgoCD reconciles from has to be
// there and have content.
//
// Asserted through the UI rather than /api/v1: Forgejo's API authenticates with
// tokens, not with the browser session, so an API call here would test token
// handling that humans never use and report a working SSO login as broken.

const { test, expect } = require('@playwright/test');
const { services, gitopsRepoUrl } = require('../lib/env');
const { signIn } = require('../lib/sso');
const { apiFetch } = require('../lib/http');

test.describe('forgejo', () => {
  test.beforeEach(async ({ page }) => {
    // Start at the login page: the Keycloak link only exists on /user/login,
    // and the landing page's "Sign in" goes to the local password form. The
    // pattern matches that one link and nothing else for the same reason.
    await signIn(page, `${services.forgejo}/user/login`, { button: /sign in with keycloak/i });
  });

  test('the Keycloak identity is signed in', async ({ page }) => {
    // Signed out, Forgejo offers "Sign in" in the navigation bar; signed in, it
    // offers a dashboard instead.
    await expect(page.getByRole('link', { name: /^sign in$/i })).toHaveCount(0);
    await expect(page.locator('body')).toContainText(/dashboard|repositories|activities/i, { timeout: 30_000 });
  });

  test('the GitOps repository exists and has commits', async ({ page }) => {
    test.skip(!gitopsRepoUrl, 'gitops.repoUrl is not set in config.yaml');

    const res = await page.goto(gitopsRepoUrl, { waitUntil: 'domcontentloaded' });
    expect(
      res.status(),
      `${gitopsRepoUrl} → ${res.status()} — ArgoCD reconciles from this repository, so it has to exist and be readable`,
    ).toBe(200);

    // A repository that exists but was never pushed to shows the "quick guide"
    // rather than a file tree, and would pass a check that only asked whether
    // the page loads.
    await expect(page.locator('body'), 'the repository is empty — nothing was pushed to it').not.toContainText(
      /quick guide/i,
    );
    await expect(page.locator('body')).toContainText(/commits?|branch/i, { timeout: 30_000 });
  });

  test('the container registry answers', async ({ page }) => {
    // Unauthenticated /v2/ returning 401 is the registry working: it is asking
    // for a token. A 404 means the route or the feature is missing.
    const res = await apiFetch(page, `${services.forgejo}/v2/`);
    expect([200, 401], `registry returned ${res.status}`).toContain(res.status);
  });
});
