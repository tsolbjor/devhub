# Local Development Setup (Windows + WSL)

This guide sets up trusted HTTPS for local Kubernetes development on Windows with WSL2.

## Prerequisites

- Windows 10/11
- WSL2 (Ubuntu or similar)
- Rancher Desktop (or another local Kubernetes distribution)
- `kubectl`, `helm`, `openssl`, `jq`, `envsubst`, `curl` in WSL

## Quick Start (Automated)

```bash
# Guided, resumable (recommended if anything goes wrong mid-way)
./devhub quickstart --env local

# Or the one-shot equivalent
cd k8s/scripts
./setup-all.sh --env local
```

This command:
1. Generates local CA and wildcard localhost certs
2. Prepares the cluster (Envoy Gateway is installed with the platform)
3. Deploys platform services
4. Initializes and configures Vault
5. Configures Keycloak realm and OIDC clients
6. Bootstraps ArgoCD app-of-apps

## Manual Setup (Step by Step)

### 1. Generate certificates (WSL)

```bash
cd k8s/scripts
./setup-ca.sh --env local
```

### 2. Trust CA + hosts entries on Windows (PowerShell as Administrator)

```powershell
cd k8s\scripts\windows
.\setup-all.ps1
```

Or run separately:

```powershell
.\install-ca.ps1
.\setup-hosts.ps1
```

### 3. Install ingress and cluster resources (WSL)

```bash
cd k8s/scripts
./setup-cluster.sh --env local
```

### 4. Deploy platform services (WSL)

```bash
cd k8s/scripts
./deploy.sh --env local
```

### 5. Configure Keycloak and Vault (WSL)

```bash
cd k8s/scripts
./setup-keycloak.sh --env local all
./setup-vault.sh --env local all

# Move platform credentials into Vault; External Secrets delivers them afterwards
./deploy.sh --env local platform-secrets

# GitOps: app-of-apps, then let ArgoCD own the platform components
./deploy.sh --env local bootstrap
./deploy.sh --env local gitops
```

### Give ArgoCD something to read

`gitops` points ArgoCD at `gitops.repoUrl` from
[overlays/local/config.yaml](../overlays/local/config.yaml) —
`https://git.localhost/devhub/devhub.git` by default. Until that repository exists,
every platform Application sits at `Sync=Unknown`; the components keep running,
because they were installed with Helm first, but nothing reconciles.

Publish it once Forgejo is up:

```bash
./devhub gitops-repo --env local
```

This creates the repository in the environment's own Forgejo, pushes a
standalone copy of the platform into it, and registers the credentials with
ArgoCD. From then on the environment is independent of this devhub checkout.
(In-cluster, ArgoCD clones Forgejo's Service name rather than
`git.localhost` — glibc resolves `*.localhost` to loopback inside pods.)

Then verify the whole environment from a browser:

```bash
./devhub validate --e2e --env local
```

## Access URLs

- https://keycloak.localhost — identity (Keycloak, run by its operator)
- https://vault.localhost — secrets
- https://git.localhost — Forgejo: repositories, issues, packages, container registry
- https://ci.localhost — Woodpecker CI
- https://argocd.localhost — GitOps
- https://grafana.localhost — dashboards
- https://prometheus.localhost — metrics
- https://headlamp.localhost — cluster UI
- https://home.localhost — Homepage: links to all of the above

## Credentials

```bash
# Keycloak admin
kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d

# Grafana admin
kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

# ArgoCD admin
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# Forgejo root
kubectl get secret forgejo-forgejo-initial-root-password -n forgejo -o jsonpath='{.data.password}' | base64 -d
```

Keycloak-generated OIDC secrets are written to `k8s/scripts/local/oidc-secrets.env`.

## Troubleshooting

### Certificates not trusted

1. Re-run `install-ca.ps1` as Administrator.
2. Restart browser.
3. Verify in `certmgr.msc` under Trusted Root Certification Authorities.

### Domain not resolving

1. Check `C:\Windows\System32\drivers\etc\hosts`.
2. Run `ipconfig /flushdns`.

### Ingress issues

```bash
kubectl get pods -n envoy-gateway-system
kubectl get svc -n envoy-gateway-system   # the Envoy data-plane LoadBalancer
kubectl get gateway -A                    # ADDRESS empty means no LoadBalancer IP
```

### Gateway stuck with no ADDRESS (`AddressNotAssigned`)

Almost always Traefik. Rancher Desktop's k3s installs it from a packaged manifest
on **every start**, and its klipper-lb pod takes host ports 80/443 — so Envoy's
own LoadBalancer Service stays `<pending>`, the Gateway never gets an address,
and nothing is reachable. The give-away:

```bash
kubectl get pods -n kube-system | grep svclb   # svclb-envoy-... Pending
```

Clear it, and note that this is why the fix has to be re-run after a Rancher
Desktop restart:

```bash
./devhub cluster --env local
```

`quickstart` checks for this as the "Cluster prerequisites" step, so
`./devhub quickstart` re-runs it on its own. To stop Traefik coming back at all:
**Rancher Desktop → Preferences → Kubernetes → uncheck "Enable Traefik"**.

### Service communication over HTTPS fails

Ensure `local-ca-certificates` ConfigMap is mounted and app CA env var is set (`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, etc.).

## Add More Local Domains

1. Edit [setup-ca.sh](../scripts/setup-ca.sh) and add entries to `DOMAINS`.
2. Re-run `./setup-ca.sh --env local`.
3. Re-run `k8s/scripts/windows/setup-hosts.ps1`.
4. Add a listener in [overlays/local/devops/gateway.yaml](../overlays/local/devops/gateway.yaml) and a route in [httproutes.yaml](../overlays/local/devops/httproutes.yaml).

## Firefox

Firefox uses its own certificate store. Import `k8s/certs/ca/ca.crt` into Firefox Authorities and trust it for websites.

## Validate without a cluster

The same static checks CI runs — YAML, duplicate keys, config keys, and whether
every `${PLACEHOLDER}` can actually be substituted:

```bash
cd k8s/scripts
./validate-overlays.sh
./validate-overlays.sh --helm local    # also render every chart
```

## Day-two operations

Backups and restore, secret rotation, GitOps handover, alerting:
[OPERATIONS.md](OPERATIONS.md).
