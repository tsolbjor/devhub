// Prometheus, direct: rules loaded and no alert firing that says the platform
// is broken.
//
// Grafana's tests prove the datasource works; this one reads the alerting state
// that a human would otherwise only see after being paged. Backup failures in
// particular are invisible everywhere else until a restore is needed.

const { test, expect } = require('@playwright/test');
const { services, ENV } = require('../lib/env');
const { isControlPlaneAlert, isControlPlaneJob } = require('../lib/noise');
const { apiJson } = require('../lib/http');

// k3s subsumes the control-plane components kube-prometheus-stack expects to
// scrape separately. See lib/noise.js — the exemption is local-only and narrow.
const local = ENV === 'local';

test.describe('prometheus', () => {
  test('has scrape targets up', async ({ page }) => {
    const res = await apiJson(page, `${services.prometheus}/api/v1/targets?state=active`);
    expect(res.status, `targets → ${res.status}`).toBe(200);

    const targets = res.json.data.activeTargets || [];
    expect(targets.length, 'no active scrape targets').toBeGreaterThan(0);

    const down = targets
      .filter((t) => t.health === 'down')
      .filter((t) => !(local && isControlPlaneJob(t.labels.job)));
    expect(
      down.map((t) => `${t.labels.job}: ${t.lastError}`),
      'scrape targets are down',
    ).toHaveLength(0);
  });

  test('platform alert rules are loaded', async ({ page }) => {
    const res = await apiJson(page, `${services.prometheus}/api/v1/rules`);
    expect(res.status).toBe(200);

    const groups = res.json.data.groups || [];
    expect(groups.length, 'no rule groups — platform-alerts.yaml never loaded').toBeGreaterThan(0);
  });

  test('no critical alert is firing', async ({ page }) => {
    const res = await apiJson(page, `${services.prometheus}/api/v1/alerts`);
    expect(res.status).toBe(200);

    const firing = (res.json.data.alerts || [])
      .filter((a) => a.state === 'firing' && (a.labels.severity || '').toLowerCase() === 'critical')
      .filter((a) => !(local && isControlPlaneAlert(a.labels.alertname)));
    expect(
      firing.map((a) => a.labels.alertname),
      'critical alerts are firing',
    ).toHaveLength(0);
  });
});
