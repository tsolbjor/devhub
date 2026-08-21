// ArgoCD: signed in through Keycloak, and every platform Application actually
// reconciling.
//
// Sync status is the honest measure of whether the GitOps handover worked. An
// Application stuck at Unknown usually means ArgoCD cannot read the
// environment's repository at all — the same condition quickstart's
// gitops-repo detector looks for.

const { test, expect } = require('@playwright/test');
const { services } = require('../lib/env');
const { signIn } = require('../lib/sso');
const { apiJson } = require('../lib/http');

test.describe('argocd', () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page, services.argocd, { button: /log in via keycloak|keycloak/i });
  });

  test('the OIDC session is accepted by the API', async ({ page }) => {
    const res = await apiJson(page, `${services.argocd}/api/v1/session/userinfo`);
    expect(res.status, `userinfo → ${res.status}`).toBe(200);
    expect(res.json.loggedIn, 'ArgoCD did not accept the Keycloak session').toBeTruthy();
  });

  test('platform Applications are synced and healthy', async ({ page }) => {
    const res = await apiJson(page, `${services.argocd}/api/v1/applications`);
    expect(res.status, `applications → ${res.status}`).toBe(200);

    const apps = res.json.items || [];
    expect(apps.length, 'no Applications — the ApplicationSet never generated any').toBeGreaterThan(0);

    const state = apps.map((a) => ({
      name: a.metadata.name,
      sync: a.status?.sync?.status || 'Unknown',
      health: a.status?.health?.status || 'Unknown',
    }));

    // Unknown means ArgoCD could not read the repository. That is a different
    // failure from a component being unhealthy, and worth its own message.
    const unreadable = state.filter((s) => s.sync === 'Unknown');
    expect(unreadable, `ArgoCD cannot read the repo for: ${unreadable.map((s) => s.name).join(', ')}`)
      .toHaveLength(0);

    const outOfSync = state.filter((s) => s.sync !== 'Synced');
    expect(outOfSync, `out of sync: ${outOfSync.map((s) => `${s.name}=${s.sync}`).join(', ')}`).toHaveLength(0);

    const unhealthy = state.filter((s) => !['Healthy', 'Progressing'].includes(s.health));
    expect(unhealthy, `unhealthy: ${unhealthy.map((s) => `${s.name}=${s.health}`).join(', ')}`).toHaveLength(0);
  });

  test('the ApplicationSet points at the environment repository', async ({ page }) => {
    const res = await apiJson(page, `${services.argocd}/api/v1/applications`);
    const apps = res.json.items || [];

    const sources = apps.flatMap((a) => a.spec?.sources || [a.spec?.source]).filter(Boolean);
    const repoUrls = sources.map((s) => s.repoURL).join(' ');

    // A placeholder that survived templating would be visible right here.
    expect(repoUrls, 'an Application still carries an unrendered ${VAR}').not.toContain('${');
  });
});
