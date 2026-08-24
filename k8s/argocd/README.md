# ArgoCD Application Management

This directory contains ArgoCD Application and ApplicationSet definitions for managing workloads via GitOps.

## Directory Structure

```
argocd/
├── apps/                    # Application definitions
│   ├── app-of-apps.yaml     # Root application (deploys all apps)
│   └── *.yaml               # Individual application manifests
├── projects/                # ArgoCD Project definitions
│   ├── platform.yaml        # The platform's own components
│   └── workloads.yaml       # Developer apps on the workload clusters
└── README.md
```

## How It Works

1. **App-of-Apps Pattern**: The root application (`apps/app-of-apps.yaml`) manages all other applications
2. **GitOps Flow**: Changes to application manifests trigger automatic sync in ArgoCD
3. **Projects**: ArgoCD Projects define RBAC and allowed resources for applications

## Adding a New Application

1. Create an Application manifest in `argocd/apps/`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: workloads
  source:
    repoURL: https://forgejo.localhost/devhub/my-service.git
    targetRevision: HEAD
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: devhub
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

2. The app-of-apps will automatically pick it up on next sync

## Sync Policies

- **Automated Sync**: Applications auto-sync when Git changes detected
- **Self-Heal**: ArgoCD corrects drift from Git state
- **Prune**: Orphaned resources are automatically deleted

## Manual Operations

```bash
# List all applications
argocd app list

# Sync an application
argocd app sync my-service

# Get application status
argocd app get my-service

# Force refresh
argocd app get my-service --refresh
```

## Environment-Specific Deployments

Use ApplicationSets for multi-environment deployments:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: my-service
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: local
            namespace: devhub
          - env: staging
            namespace: devhub-staging
  template:
    metadata:
      name: 'my-service-{{env}}'
    spec:
      project: workloads
      source:
        repoURL: https://forgejo.localhost/devhub/my-service.git
        path: 'k8s/overlays/{{env}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{namespace}}'
```

---

## Current topology

| Manifest | What it manages |
|----------|-----------------|
| `apps/app-of-apps.yaml` | Everything else in `apps/`. Its `repoURL` is templated from `gitops.repoUrl` in the environment's `config.yaml` — it used to be hardcoded to `https://forgejo.localhost`, which broke every cloud bootstrap. |
| `platform-appset.yaml` | The platform itself: cert-manager, external-dns, external-secrets, monitoring, loki, tempo, alloy, kyverno, reloader, woodpecker, headlamp, velero. Applied once by `deploy.sh --env <env> gitops`; charts come from upstream repos with values from this repo (`$values`). |
| `apps/forgejo-appset.yaml` | Developer apps: a **matrix** of Forgejo repositories in the `devhub` organisation × clusters labelled `devhub.io/role=workload`. Apps therefore land on workload clusters, not on the platform cluster. |
| `projects/*.yaml` | AppProjects, and the security boundary for everything above. `platform`: the GitOps repo plus the enumerated upstream chart repos, the in-cluster destination only, an explicit `clusterResourceWhitelist`. `workloads`: `devhub-*` namespaces on `name: '*-workload'` clusters, with an explicit `namespaceResourceWhitelist` — NetworkPolicy, Role/RoleBinding and `kyverno.io/*` are deliberately absent (see the comments in the file for why each would undo a guardrail). RBAC is bound to the Keycloak groups `devops-admins` / `developers`. |

> These files are applied **verbatim** by `deploy.sh` — there is no
> `template_values` pass over `projects/`, so a `${VAR}` placeholder would reach
> the cluster unsubstituted. Use glob patterns instead.

### Adding a platform component

1. Base values → `k8s/base/devops/<component>/values.yaml`
2. Per-cloud overrides → `k8s/overlays/<cloud>/devops/<component>/values.yaml`
3. An entry in `platform-appset.yaml` (chart, repo, version, namespace, value paths)
4. `./deploy.sh --env <env> gitops`

`k8s/scripts/validate-overlays.sh` checks that every value path referenced by the
ApplicationSet actually exists.
