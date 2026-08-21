// Woodpecker: authenticated through Forgejo's OAuth app, with agents connected.
//
// The OAuth application is created by deploy.sh's configure_woodpecker_oauth
// step, and it is the piece that silently rots — a re-deployed Forgejo issues
// new client credentials and Woodpecker's login starts failing. An agent count
// of zero means pipelines queue forever, which no page-loads check would show.

const { test, expect } = require('@playwright/test');
const { services } = require('../lib/env');
const { signIn } = require('../lib/sso');
const { apiJson } = require('../lib/http');

test.describe('woodpecker', () => {
  test('logs in through Forgejo and knows the user', async ({ page }) => {
    await signIn(page, services.woodpecker, { button: /login with|sign in with|^login$/i });

    const res = await apiJson(page, `${services.woodpecker}/api/user`);
    expect(res.status, 'Woodpecker did not accept the Forgejo OAuth login').toBe(200);
    expect(res.json.login).toBeTruthy();
  });

  test('has at least one agent connected', async ({ page }) => {
    await signIn(page, services.woodpecker, { button: /login with|sign in with|^login$/i });

    const res = await apiJson(page, `${services.woodpecker}/api/agents`);
    // /api/agents is admin-only; a non-admin session gets 401/403 and the check
    // is not applicable rather than failed.
    test.skip(res.status === 401 || res.status === 403, 'this user is not a Woodpecker admin');

    expect(res.status).toBe(200);
    expect(res.json.length, 'no agents are connected — pipelines would queue forever').toBeGreaterThan(0);
  });

  test('can see repositories from Forgejo', async ({ page }) => {
    await signIn(page, services.woodpecker, { button: /login with|sign in with|^login$/i });

    // Not "there is at least one repo": a fresh platform legitimately has none
    // enabled. The signal is that Woodpecker can talk to Forgejo at all.
    const res = await apiJson(page, `${services.woodpecker}/api/user/repos`);
    expect(res.status, 'Woodpecker cannot reach Forgejo with the stored token').toBe(200);
    expect(Array.isArray(res.json)).toBeTruthy();
  });
});
