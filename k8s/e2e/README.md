# End-to-end validation

```bash
./devhub validate --e2e --env local            # everything
./devhub validate --e2e --env local --grep grafana
./devhub validate --e2e --env local --headed   # watch it
./devhub validate --e2e --env local --report   # open the HTML report afterwards
```

`./devhub validate` (without `--e2e`) is the static check: YAML, config keys,
placeholder allow-list, `helm template`. It needs no cluster and runs in CI.
This suite is the other half — it signs in to a **deployed** environment with a
real Keycloak password and asserts on what each service returns.

The gap it closes is the failure mode where every pod is `Running` and the
platform is unusable:

| Symptom | What the pods say | What this catches it with |
|---|---|---|
| Keycloak realm gone after the database was recreated | all healthy | `realm devops is published` |
| A Helm value still containing the literal `${DOMAIN}` | all healthy | `no service is serving an unrendered ${VAR}`, and the service's own test |
| ArgoCD cannot read the environment repository | all healthy | Applications reporting `Unknown` |
| Loki ingesting nothing | all healthy | `Loki has ingested logs` |
| Headlamp falling back to token auth because OIDC is not wired | all healthy | `offers Keycloak sign-in rather than a token prompt` |
| Vault sealed | `1/1 Running` | `is initialised and unsealed` |

## How it is put together

- **One sign-in.** `global-setup.js` logs in to the realm once and saves the
  storage state. Every test reuses it, so each service has to complete its OIDC
  flow *silently* — which is what SSO means. A service that shows a password
  form fails with that as the message.
- **Everything goes through Chromium**, including API calls (`lib/http.js`).
  Playwright's `request` fixture runs in Node, which resolves `*.localhost`
  through glibc and fails; Chromium resolves it to loopback itself. Requests
  from the page also carry exactly the session the user has.
- **Read-only.** No repository is created, no pipeline triggered, no secret
  written. Safe against production.
- **Serial** (`workers: 1`). The tests share one realm session.
- **No retries.** A flake is a finding; re-running is cheap.

## Files

| Path | What it is |
|---|---|
| `playwright.config.js` | timeouts, reporters, storage state, serial execution |
| `global-setup.js` | the one Keycloak sign-in |
| `lib/env.js` | domain, service URLs, credentials — from `validate-e2e.sh` |
| `lib/sso.js` | sign-in helpers, and `appears()` (see below) |
| `lib/http.js` | in-browser fetch: `apiFetch`, `apiJson` |
| `lib/noise.js` | what a single-node k3s cannot satisfy, exempted on local only |
| `tests/NN-<service>.spec.js` | one file per service, numbered to order the run |

## Adding a check

Add it to the service's spec, or add `tests/NN-<service>.spec.js` for a new
service and a URL for it in `lib/env.js`. Two rules that came out of writing
this suite:

- **Assert on data, not on the page loading.** "Grafana renders" passes with
  every datasource broken. `up` returning results, Loki returning labels, and
  ArgoCD reporting `Synced` are what a working platform looks like.
- **Never `locator.isVisible({ timeout })`.** The option does nothing — the call
  answers from the current DOM and returns `false` for anything still loading.
  Use `appears(locator, ms)` from `lib/sso.js`, which waits.

## Local exemptions

k3s runs the scheduler, controller-manager and kube-proxy inside one binary and
exposes none of their metrics endpoints, so kube-prometheus-stack's targets for
them are permanently down and their alerts permanently firing. `lib/noise.js`
exempts exactly those, on `local` only. Everything else — a crashlooping
Alertmanager, a Loki that stopped ingesting — fails the local run too.
