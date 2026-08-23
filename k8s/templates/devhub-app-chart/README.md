# devhub-app

The opinionated chart every scaffolded application renders through. An app
repository carries one file — `k8s/values.yaml` — and this chart turns it into
the platform's idea of a well-behaved workload:

- hardened Deployment (non-root, read-only rootfs, no capabilities, seccomp,
  `workload-default` priority), health probes, conservative resources
- ClusterIP Service and a Gateway API HTTPRoute on the platform gateway's
  wildcard `apps` listener — TLS, DNS and certificates are the platform's job
- PodDisruptionBudget (when replicas > 1) and baseline NetworkPolicies
  (mirroring what Kyverno generates for every `devhub-*` namespace)
- registry pull secret via External Secrets from the platform Vault
- opt-in dev-grade PostgreSQL (`postgres.enabled`) and Redis (`redis.enabled`):
  password generated in-cluster, connection env vars (`POSTGRES_*`, `REDIS_*`)
  injected into the app container automatically
- opt-in sign-in at the gateway via the platform Keycloak (`auth.enabled`):
  Envoy Gateway runs the OIDC flow with the shared `apps` client, the app
  stays auth-unaware. `auth.exceptPaths` flips the rule per path — public
  exceptions on a protected app (`/healthz`, webhooks), or protected
  exceptions on a public app (`/admin`)

## Minimal values.yaml

```yaml
app:
  name: my-service
  host: my-service.example.com
  port: 8080
  image:
    repository: git.example.com/devhub/my-service
    tag: latest        # CI rewrites this on every push to main
registry:
  host: git.example.com
postgres:
  enabled: true
redis:
  enabled: false
auth:
  enabled: true                       # sign-in required everywhere…
  exceptPaths: ["/healthz", "/api/webhook"]   # …except these
  issuer: https://keycloak.example.com/realms/devops
```

See `values.yaml` in this repository for every knob (replicas, resources,
probes, extra env, `extraManifests`).

## How it is deployed

The platform ArgoCD's `forgejo-workloads-chart` ApplicationSet matches every
`devhub`-org repository containing `k8s/values.yaml` and renders it through
this chart (HEAD of this repository) onto each registered workload cluster.
Nothing to configure per app.

Outgrown the chart? Add one-offs under `extraManifests`, or eject: delete
`k8s/values.yaml` and commit raw manifests to `k8s/` — the raw ApplicationSet
deploys the directory as-is.

## Where it comes from

Published from the devhub platform repository (`k8s/templates/devhub-app-chart`)
by `deploy.sh --env <env> portal-templates`, as a force-push of a fresh tree.
Edits here are overwritten by the next republish; edits to HEAD are fleet-wide
on the next sync either way — every chart-based app re-renders.
