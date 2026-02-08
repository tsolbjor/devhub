# ArgoCD Application Management

This directory contains ArgoCD Application and ApplicationSet definitions for managing workloads via GitOps.

## Directory Structure

```
argocd/
├── apps/                    # Application definitions
│   ├── app-of-apps.yaml     # Root application (deploys all apps)
│   └── *.yaml               # Individual application manifests
├── projects/                # ArgoCD Project definitions
│   └── tshub.yaml           # Main project for tshub applications
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
  project: tshub
  source:
    repoURL: https://gitlab.local.dev/tshub/my-service.git
    targetRevision: HEAD
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: tshub
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
            namespace: tshub
          - env: staging
            namespace: tshub-staging
  template:
    metadata:
      name: 'my-service-{{env}}'
    spec:
      project: tshub
      source:
        repoURL: https://gitlab.local.dev/tshub/my-service.git
        path: 'k8s/overlays/{{env}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{namespace}}'
```
