// Grafana: signed in through Keycloak with an admin role, and its three data
// sources actually returning data.
//
// "Grafana loads" is close to worthless as a check — it loads with every
// datasource broken. What matters is that Prometheus has scraped, Loki has
// ingested (it runs with auth_enabled, so a missing tenant header shows up
// here), and Tempo answers.

const { test, expect } = require('@playwright/test');
const { services } = require('../lib/env');
const { signIn } = require('../lib/sso');
const { apiJson } = require('../lib/http');

const GRAFANA_BUTTON = /sign in with keycloak|keycloak/i;

// Grafana's proxy endpoint is the honest way to query a datasource: it uses the
// datasource's own credentials and network path, so a pass means a dashboard
// would render, not merely that the URL is reachable from the test.
const proxy = (uid, path) => `${services.grafana}/api/datasources/proxy/uid/${uid}${path}`;

async function datasources(page) {
  const res = await apiJson(page, `${services.grafana}/api/datasources`);
  expect(res.status, `GET /api/datasources → ${res.status} ${res.body.slice(0, 200)}`).toBe(200);
  return res.json;
}

test.describe('grafana', () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page, services.grafana, { button: GRAFANA_BUTTON });
  });

  test('signs in with the platform admin role', async ({ page }) => {
    const user = await apiJson(page, `${services.grafana}/api/user`);
    expect(user.status, 'Grafana did not accept the OIDC session').toBe(200);
    expect(user.json.login || user.json.email).toBeTruthy();

    // role_attribute_path maps devops-admins → Admin. Anything less means the
    // groups claim did not arrive, which breaks more than Grafana.
    const orgs = await apiJson(page, `${services.grafana}/api/user/orgs`);
    expect(
      (orgs.json || []).some((o) => o.role === 'Admin'),
      `platform-admin is not a Grafana Admin (${JSON.stringify(orgs.json)}) — check the groups claim`,
    ).toBeTruthy();
  });

  test('Prometheus, Loki and Tempo are configured and healthy', async ({ page }) => {
    const all = await datasources(page);
    const types = all.map((d) => d.type);

    for (const type of ['prometheus', 'loki', 'tempo']) {
      expect(types, `no ${type} datasource`).toContain(type);
    }

    for (const ds of all.filter((d) => ['prometheus', 'loki', 'tempo'].includes(d.type))) {
      const health = await apiJson(page, `${services.grafana}/api/datasources/uid/${ds.uid}/health`);
      const status = (health.json && health.json.status ? health.json.status : '').toUpperCase();
      expect(
        health.status === 200 && status === 'OK',
        `${ds.name} health check: HTTP ${health.status} ${health.body.slice(0, 200)}`,
      ).toBeTruthy();
    }
  });

  test('Prometheus has scraped the platform', async ({ page }) => {
    const ds = (await datasources(page)).find((d) => d.type === 'prometheus');
    const res = await apiJson(page, proxy(ds.uid, '/api/v1/query?query=up'));

    expect(res.status).toBe(200);
    expect(res.json.status).toBe('success');

    const up = res.json.data.result.filter((r) => r.value[1] === '1');
    expect(up.length, 'almost nothing is up — Prometheus is scraping, but the platform is not there').toBeGreaterThan(5);
  });

  test('Loki has ingested logs', async ({ page }) => {
    const ds = (await datasources(page)).find((d) => d.type === 'loki');
    const res = await apiJson(page, proxy(ds.uid, '/loki/api/v1/labels'));

    expect(res.status, `Loki rejected the read (${res.body.slice(0, 200)}) — check the tenant header`).toBe(200);
    expect(res.json.data || [], 'Loki has no labels, so Alloy has shipped nothing').toContain('namespace');
  });

  test('Tempo is queryable', async ({ page }) => {
    const ds = (await datasources(page)).find((d) => d.type === 'tempo');
    const res = await apiJson(page, proxy(ds.uid, '/api/search/tags'));

    // An empty tag list is fine on a platform nobody has traced yet; an error
    // is not.
    expect(res.status, `Tempo returned ${res.status}: ${res.body.slice(0, 200)}`).toBe(200);
  });
});
