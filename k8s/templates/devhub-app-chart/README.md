# devhub-app

The opinionated chart every scaffolded application renders through. An app
repository carries one file — `k8s/values.yaml` — and this chart turns it into
the platform's idea of a well-behaved workload:

- hardened Deployment (non-root, read-only rootfs, no capabilities, seccomp,
  `workload-default` priority), health probes, conservative resources
- ClusterIP Service and a Gateway API HTTPRoute on the platform gateway's
  wildcard `apps` listener — TLS, DNS and certificates are the platform's job
- PodDisruptionBudget (when replicas > 1). NetworkPolicies are deliberately
  NOT in the chart: Kyverno generates them for every `devhub-*` namespace with
  `synchronize: true`, so a chart-rendered copy under the same names would
  fight ArgoCD forever (permanent OutOfSync)
- registry pull secret via External Secrets from the platform Vault
- opt-in dev-grade PostgreSQL (`postgres.enabled`) and Redis (`redis.enabled`):
  password generated in-cluster, connection env vars (`POSTGRES_*`, `REDIS_*`)
  injected into the app container automatically. **Dev-grade is the
  specification, not modesty**: single replica, no backups, no failover, and
  the PVC dies with the app. Production data belongs on the managed database
  the platform provisions per cloud — see `values.yaml` for the full contract
- opt-in horizontal autoscaling (`autoscaling.enabled`): an `autoscaling/v2`
  HPA on CPU utilisation. While enabled the Deployment omits `replicas`
  entirely so the HPA is its single owner (otherwise ArgoCD's sync and the
  autoscaler overwrite each other), and the PodDisruptionBudget floor becomes
  `autoscaling.minReplicas`
- opt-in `initContainers`, rendered verbatim into the app's pod spec — the
  chart's **database-migration hook**, so an app need not migrate in-process on
  startup. Same Kyverno rules as any container (requests *and* limits, non-root,
  allow-listed registry); the migration must be idempotent, safe to run
  concurrently across a rollout, and backward compatible with the image still
  serving
- off-the-shelf containers beside the app (`extraWorkloads`): any image from a
  Kyverno-allow-listed registry (ghcr.io, quay.io, docker.io/library,
  registry.k8s.io, the platform registry), no CI involved — hardened
  Deployment + Service per entry, an HTTPRoute when it has a `host`
  (`docs-<app>.<domain>`), and gateway sign-in when it sets `auth: true`.
  Public images that need their own uid or writable paths set `runAsUser` /
  `writableDirs`; root stays forbidden
- opt-in sign-in at the gateway via the platform Keycloak (`auth.enabled`):
  Envoy Gateway runs the OIDC flow with the shared `apps` client, the app
  stays auth-unaware. `auth.exceptPaths` flips the rule per path — public
  exceptions on a protected app (`/healthz`, webhooks), or protected
  exceptions on a public app (`/admin`)
- opt-in MCP endpoint (`mcp.enabled`): the gateway validates Bearer JWTs
  (issuer + `aud: mcp`) on `mcp.path` and serves the RFC 9728 discovery
  document at `/.well-known/oauth-protected-resource`, so MCP clients (Claude
  Code, VS Code) find Keycloak, sign in through the brokered IdP and — via the
  advertised `offline_access` scope — keep a long-lived connection. Requires
  the one-time realm prep `setup-keycloak.sh mcp`. Independent of
  `auth.enabled`: browser sign-in and token clients coexist on one hostname

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
probes, extra env, `extraHosts`, `autoscaling`, `initContainers`,
`extraWorkloads`, `extraManifests`).

## Database migrations

There is no separate migration Job: the hook is `initContainers`, which runs to
completion before the app container starts, on every pod.

```yaml
initContainers:
  - name: migrate
    image: git.example.com/devhub/my-service:latest   # usually the app image
    command: ["/app/migrate"]
    env:
      - name: POSTGRES_HOST
        value: my-service-postgres
      - name: POSTGRES_PASSWORD
        valueFrom: { secretKeyRef: { name: my-service-postgres, key: password } }
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: ["ALL"] }
    resources:
      requests: { cpu: 50m, memory: 64Mi }
      limits: { cpu: 500m, memory: 256Mi }
```

The `POSTGRES_*` / `REDIS_*` env vars the chart injects into the *app* container
are not injected here — repeat the `secretKeyRef`s you need. During a rolling
update this runs in several pods at once, alongside the old image still serving,
so migrations must be idempotent, concurrency-safe (most migration tools take an
advisory lock — confirm yours does) and backward compatible with the previous
release.

## App ecosystems: more than one hostname

The platform's wildcard certificate and apps listener cover `*.<domain>`
exactly one label deep, so the ecosystem convention is suffix grouping:
`<app>.<domain>` is the landing page, siblings are `api-<app>.<domain>`,
`admin-<app>.<domain>` and so on.

- Same deployment answering several names → `app.extraHosts`.
- A separate deployable (own image, own CI, own lifecycle) → its own portal
  scaffold, named `api-<app>`.

True `*.<app>.<domain>` subdomains need a per-app listener and certificate,
which Gateway API's ListenerSet will make self-service once Envoy Gateway's
support stabilises — the DNS-01 issuing it depends on already works here.

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
