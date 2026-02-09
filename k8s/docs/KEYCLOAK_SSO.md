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

### 3. GitLab
- **URL**: https://gitlab.localhost
- **OIDC Client**: `gitlab`
- **Login**: Click "Keycloak" button on login page
- **User Creation**: Users are auto-created on first login

**Configuration**:
- Values file: `k8s/overlays/local/devops/gitlab/values.yaml`
- Secret: `gitlab-oidc-secret` in `gitlab` namespace
- Auth provider: OmniAuth OpenID Connect

### 4. Vault
- **URL**: https://vault.localhost
- **OIDC Client**: `vault`
- **Login**: Configured via Vault OIDC auth method
- **Setup**: Requires manual configuration after Vault initialization

**Configuration**:
- Secret: `vault-oidc-secret` in `vault` namespace
- Auth method must be enabled via Vault CLI

## Users and Groups

### Default Admin User
- **Username**: `devops-admin`
- **Password**: Generated during setup, saved in `k8s/scripts/local/oidc-secrets.env`
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
./scripts/local/setup-all.sh

# Or run Keycloak configuration separately
cd k8s/scripts/local
export DOMAIN=localhost
./setup-keycloak.sh all
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
   - `gitlab-oidc-secret` (gitlab namespace)
   - `vault-oidc-secret` (vault namespace)

2. **Local File**: `k8s/scripts/local/oidc-secrets.env` (gitignored)
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

### GitLab Keycloak Button Not Visible

1. Verify GitLab OmniAuth configuration is applied
2. Check GitLab webservice logs: `kubectl logs -n gitlab deployment/gitlab-webservice-default`
3. Restart GitLab webservice: `kubectl rollout restart deployment/gitlab-webservice-default -n gitlab`

### User Cannot Access Service After Login

1. Verify user is in correct group (devops-admins, developers, or viewers)
2. Check group mappings in Keycloak Admin Console
3. Try logging out and logging back in

### Keycloak Setup Script Fails

1. Ensure Keycloak is fully running: `kubectl get pods -n keycloak`
2. Check Keycloak logs: `kubectl logs -n keycloak keycloak-keycloakx-0`
3. Try running individual steps:
   ```bash
   ./setup-keycloak.sh realm    # Create realm only
   ./setup-keycloak.sh clients  # Configure clients only
   ./setup-keycloak.sh user     # Create admin user only
   ```

## Security Considerations

### Client Secrets
- Client secrets are stored in Kubernetes secrets (encrypted at rest if cluster encryption is enabled)
- Secrets are not committed to git (oidc-secrets.env is gitignored)
- Rotate secrets periodically in production environments

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
- [GitLab OmniAuth Documentation](https://docs.gitlab.com/ee/integration/omniauth.html)
- [OpenID Connect Specification](https://openid.net/connect/)
