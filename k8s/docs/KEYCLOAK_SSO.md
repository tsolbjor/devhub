# Keycloak SSO Configuration Guide

## Overview

All services in the DevOps platform are configured to use Keycloak for centralized authentication and Single Sign-On (SSO). This provides:

- **Centralized user management**: Create users once in Keycloak, access all services
- **Group-based authorization**: Assign users to groups (devops-admins, developers, viewers) for role-based access
- **Single Sign-On**: Log in once, access all services without re-authentication
- **OAuth 2.0 / OIDC**: Industry-standard authentication protocols

## Keycloak Access

- **Admin Console**: https://keycloak.localhost/admin/
  - Username: `admin`
  - Password: Retrieved with: `kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d`

- **Realm**: `devops`
- **Realm Login**: https://keycloak.localhost/realms/devops/account/

## Services Configured with SSO

### 1. Grafana
- **URL**: https://grafana.localhost
- **OIDC Client**: `grafana`
- **Login**: Click "Sign in with Keycloak" button
- **Role Mapping**:
  - `devops-admins` group → Grafana Admin
  - `developers` group → Grafana Editor
  - `viewers` group → Grafana Viewer

**Configuration**:
- Values file: `k8s/overlays/local/devops/monitoring/values.yaml`
- Secret: `grafana-oidc-secret` in `monitoring` namespace
- Auth provider: `auth.generic_oauth`

### 2. ArgoCD
- **URL**: https://argocd.localhost
- **OIDC Client**: `argocd`
- **Login**: Click "LOG IN VIA KEYCLOAK" button
- **Role Mapping**:
  - `devops-admins` group → ArgoCD Admin
  - `developers` group → Read-only access
  - `viewers` group → Read-only access

**Configuration**:
- Values file: `k8s/overlays/local/devops/argocd/values.yaml`
- Secret: `argocd-secret` in `argocd` namespace (key: `oidc.keycloak.clientSecret`)
- OIDC config in server ConfigMap

### 3. Forgejo
- **URL**: https://git.localhost
- **OIDC Client**: `forgejo`
- **Login**: Click "Keycloak" button on login page
- **User Creation**: Users are auto-created on first login

**Configuration**:
- Registered by `setup-keycloak.sh` (`register_forgejo_oidc`) through Forgejo's
  admin CLI: `gitea admin auth add-oauth --provider openidConnect`, discovery over
  the in-cluster Keycloak service URL. It is deliberately *not* in the Helm values —
  the chart's init container fails the pod if the realm does not exist yet.
- Secret: `forgejo-oidc-secret` in `forgejo` namespace (record of the credentials;
  the live configuration lives in Forgejo's database)
- Group claim `groups`, admin group `devops-admins`

### 4. Vault
- **URL**: https://vault.localhost
- **OIDC Client**: `vault`
- **Login**: Configured via Vault OIDC auth method
- **Setup**: Requires manual configuration after Vault initialization

**Configuration**:
- Secret: `vault-oidc-secret` in `vault` namespace
- Auth method must be enabled via Vault CLI

### 5. Homepage, Portal and every developer app — the gateway is the client

These three have no OIDC code of their own. An Envoy Gateway `SecurityPolicy` runs
the whole authorization-code flow at the gateway, so the pod never sees an
anonymous request and never handles a token.

| | Client | Redirect URI |
|---|---|---|
| Homepage | `homepage` | `https://home.<domain>/oauth2/callback` |
| Portal | `portal` | `https://portal.<domain>/oauth2/callback` |
| **every developer app** | **`apps` — one shared client** | **`https://*.<domain>/oauth2/callback`** |

The `apps` row is the one to read twice: it is a single confidential client, with a
wildcard redirect, whose secret is delivered into every app namespace. See
[Every developer app shares one OIDC client](#every-developer-app-shares-one-oidc-client--know-the-blast-radius)
under Security Considerations before you treat app namespaces as isolated from
each other.

## Users and Groups

### Default Admin User
- **Username**: `devops-admin`
- **Password**: Generated during setup, saved in `_setup/local/oidc-secrets.env`
- **Groups**: `devops-admins`
- **Note**: Password is temporary and must be changed on first login

### Groups
- **devops-admins**: Full administrative access to all services
- **developers**: Editor/developer access to services
- **viewers**: Read-only access to services

### Creating New Users

1. Log in to Keycloak Admin Console
2. Navigate to: Realm: devops → Users → Add user
3. Fill in user details (username, email, etc.)
4. Set password in Credentials tab
5. Assign to groups in Groups tab

## Automated Setup

The Keycloak configuration is fully automated and integrated into the deployment process:

```bash
# Run the complete setup (includes Keycloak configuration)
cd k8s/scripts
./setup-all.sh --env local

# Or run Keycloak configuration separately
cd k8s/scripts
./setup-keycloak.sh --env local all
```

### What the Script Does

1. **Creates Realm**: Creates the `devops` realm with security settings
2. **Creates Groups**: Sets up devops-admins, developers, and viewers groups
3. **Creates OIDC Clients**: Configures OAuth clients for each service
4. **Generates Secrets**: Creates Kubernetes secrets with client credentials
5. **Creates Admin User**: Creates devops-admin user with temporary password

### Client Secrets

Client secrets are stored in two places:
1. **Kubernetes Secrets**: Used by services for OIDC authentication
   - `grafana-oidc-secret` (monitoring namespace)
   - `argocd-secret` (argocd namespace)
   - `forgejo-oidc-secret` (forgejo namespace — record only; Forgejo stores the
     login source in its database)
   - `vault-oidc-secret` (vault namespace)

2. **Local File**: `_setup/local/oidc-secrets.env` (gitignored)
   - Contains all client secrets and admin password
   - Used for reference and manual configuration if needed

## OIDC Configuration Details

### Keycloak Endpoints

All services use these Keycloak endpoints:

- **Authorization Endpoint**: `https://keycloak.localhost/realms/devops/protocol/openid-connect/auth`
- **Token Endpoint**: `https://keycloak.localhost/realms/devops/protocol/openid-connect/token`
- **UserInfo Endpoint**: `https://keycloak.localhost/realms/devops/protocol/openid-connect/userinfo`
- **Issuer**: `https://keycloak.localhost/realms/devops`

### Scopes Requested

- `openid`: Required for OIDC
- `profile`: User profile information (name, etc.)
- `email`: User email address
- `groups`: Group membership for authorization

## Troubleshooting

### Grafana Shows "Login Failed"

1. Check that the Grafana pod has restarted after OIDC configuration
2. Verify the secret exists: `kubectl get secret grafana-oidc-secret -n monitoring`
3. Check Grafana logs: `kubectl logs -n monitoring deployment/prometheus-grafana`

### ArgoCD Returns 500 Error

1. Verify argocd-secret contains OIDC client secret:
   ```bash
   kubectl get secret argocd-secret -n argocd -o jsonpath='{.data.oidc\.keycloak\.clientSecret}' | base64 -d
   ```
2. Restart ArgoCD server: `kubectl rollout restart deployment argocd-server -n argocd`
3. Check ArgoCD logs: `kubectl logs -n argocd deployment/argocd-server`

### Forgejo Keycloak Button Not Visible

1. Verify the OAuth source exists: `kubectl exec -n forgejo deploy/forgejo -- forgejo admin auth list`
2. Check the Forgejo logs: `kubectl logs -n forgejo deploy/forgejo`
3. Restart Forgejo: `kubectl rollout restart deploy/forgejo -n forgejo`

### User Cannot Access Service After Login

1. Verify user is in correct group (devops-admins, developers, or viewers)
2. Check group mappings in Keycloak Admin Console
3. Try logging out and logging back in

### Keycloak Setup Script Fails

1. Ensure Keycloak is fully running: `kubectl get pods -n keycloak`
2. Check Keycloak logs: `kubectl logs -n keycloak keycloak-0`
3. Try running individual steps:
   ```bash
   ./setup-keycloak.sh --env local realm    # Create realm only
   ./setup-keycloak.sh --env local clients  # Configure clients only
   ./setup-keycloak.sh --env local user     # Create admin user only
   ```

## Security Considerations

### Every developer app shares one OIDC client — know the blast radius

This is the most important thing on this page, and it is a deliberate trade-off
rather than an oversight.

Developer applications do **not** get an OIDC client each. They share one
confidential client called `apps`:

- **one client**, created by `setup-keycloak.sh` (`require_client_secret apps_secret "apps"`)
- **one redirect URI**, a wildcard: `https://*.<domain>/oauth2/callback`. Keycloak
  accepts a single-label host wildcard, and a scaffolded app's hostname is always
  exactly `<app>.<domain>`, so one pattern covers every app that will ever exist
- **one secret**, stored in Vault at `secret/apps/oidc-gateway` and delivered by
  External Secrets into **every** app namespace, where the `devhub-app` chart's
  gateway `SecurityPolicy` uses it to run the sign-in flow

What follows from that, stated plainly:

> Any person who can read a Secret in **their own** app's namespace — or can get
> code to run in their own app's pod — holds the client credential that every
> other app's sign-in depends on.

Concretely, with that secret and the wildcard redirect, someone can:

- complete the authorization-code flow for **any** `*.<domain>` host, including
  apps they have no access to, and mint tokens as whoever signs in
- stand up a look-alike host under the wildcard and collect authorization codes
  that Keycloak will happily exchange
- force a platform-wide outage by having the secret rotated: every app's login
  breaks at once, because there is only one

The reasons it is set up this way are real — one client means no per-app Keycloak
provisioning step, no per-app redirect URI to register, and no per-app secret to
seed, so the portal can scaffold an app that has working SSO with **zero**
Keycloak interaction. That is a large part of why creating an app takes a minute.
But it means the platform's app-to-app authentication boundary is *convention*, not
enforcement, and it does not survive an app owner who is careless or hostile.

**The hardening path is per-app clients.** If your apps are not all run by the same
small trusted team, do this rather than documenting around it:

1. Create a client per app (`app-<name>`) with an exact redirect URI
   (`https://<name>.<domain>/oauth2/callback`) — no wildcard.
2. Store its secret at `secret/apps/<name>/oidc` and scope the app namespace's
   ExternalSecret to that path only, so a namespace can read its own credential
   and nothing else.
3. Give the client an audience mapper so its tokens are not accepted by other
   apps' gateways.
4. Add the client creation to the portal's scaffolding step (it already talks to
   Forgejo; this makes it talk to Keycloak too) or to a `setup-keycloak.sh`
   per-app action.

Until then, treat "can deploy an app to this platform" as equivalent to "can
impersonate the sign-in of every app on this platform", and choose who gets that
accordingly.

### Forgejo tokens are per-user, not per-repository

Forgejo has no repository-scoped access token. An access token is minted **for a
user** and carries that user's permissions across every repository and
organisation they can reach, limited only by coarse scopes
(`write:repository`, `write:organization`, `write:issue`). There is no
"this token may only touch `devhub/myapp`".

Two consequences worth knowing:

- **The portal holds one such token.** It needs
  `write:organization,write:repository,write:issue` to create a repository, seed
  it from the template and open the starter issues. Minted against the *admin*
  user, that token is administrative access to all of Forgejo, sitting in a pod
  that serves HTTP. That is why the token should belong to a dedicated bot
  account that is a member only of the `devhub` and `devhub-templates`
  organisations — the scopes cannot be narrowed, so the *identity* is the only
  place left to limit the blast radius. The portal's other defences (no
  Kubernetes RBAC at all, and a NetworkPolicy admitting only the gateway, which
  runs the Keycloak OIDC flow) exist because of this token.
- **In the app CI template, the registry token is also the git push credential.**
  `k8s/templates/app-template/.woodpecker.yml` uses the same `registry_token` org
  secret to `docker login` for the image push, to download the chart, *and* as
  `GIT_TOKEN` in the `deploy` step that commits the new image tag back to
  `k8s/values.yaml`. It cannot be otherwise: a pull-only registry token could not
  push the commit, and Forgejo cannot issue a token that pushes to one repository
  only. So the token available to every pipeline in the `devhub` org can write to
  every repository in it. It is deliberately scoped to **push events only**, so
  pull-request builds of untrusted code never see it — that restriction is doing
  most of the work here, and removing it (to "make PR builds green") would hand
  the credential to anyone who can open a pull request.

### Client Secrets
- Client secrets are stored in Kubernetes secrets (encrypted at rest if cluster encryption is enabled)
- Secrets are not committed to git (oidc-secrets.env is gitignored)
- Rotate secrets periodically in production environments — remembering that
  rotating the shared `apps` secret breaks every app's login until External
  Secrets has refreshed each namespace

### Password Policy
- Keycloak is configured with:
  - Brute force protection enabled
  - Password reset allowed
  - Email verification recommended for production

### SSL/TLS
- All OIDC communication uses HTTPS
- Keycloak requires external SSL (sslRequired: external)
- Certificate validation is performed by services

## Production Deployment

For production deployments, consider:

1. **Database**: Use external PostgreSQL for Keycloak (not bundled database)
2. **High Availability**: Deploy multiple Keycloak replicas
3. **Session Management**: Configure distributed sessions
4. **Email**: Configure SMTP for password reset and notifications
5. **Backups**: Regular backups of Keycloak database and realm configuration
6. **Secrets Management**: Use external secrets management (Vault, AWS Secrets Manager)
7. **Domain**: Use production domain (not .localhost)
8. **Certificate**: Use proper TLS certificates (Let's Encrypt, etc.)

## References

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [Grafana OAuth Documentation](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/)
- [ArgoCD SSO Documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/)
- [Forgejo OAuth2 authentication](https://forgejo.org/docs/latest/admin/oauth2-provider/)
- [OpenID Connect Specification](https://openid.net/connect/)

## Woodpecker CI is not a Keycloak client

Woodpecker authenticates users through **Forgejo**, not Keycloak: it uses a Forgejo
OAuth2 application (`WOODPECKER_GITEA_CLIENT` / `WOODPECKER_GITEA_SECRET`), which
`deploy.sh` registers automatically. Since Forgejo itself is a Keycloak client, a
user still signs in once with their Keycloak identity — the chain is
Keycloak → Forgejo → Woodpecker.

Re-register the application if the secret is lost:

```bash
./devhub deploy --env <env> woodpecker-oauth
```
