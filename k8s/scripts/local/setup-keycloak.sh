#!/bin/bash
set -euo pipefail

# =============================================================================
# Keycloak Realm and Client Configuration Script
# =============================================================================
# Creates the devops realm and configures OIDC clients for all services.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
DOMAIN="${DOMAIN:-localhost}"
REALM="devops"
KCADM="/opt/keycloak/bin/kcadm.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Execute kcadm command in Keycloak pod
kcadm() {
    kubectl exec -n keycloak keycloak-keycloakx-0 -- ${KCADM} "$@"
}

# Login to Keycloak admin
kcadm_login() {
    local password=$(kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
    kcadm config credentials --server http://localhost:8080 --realm master --user admin --password "${password}" >/dev/null
    log_info "Logged in to Keycloak admin CLI"
}

# Create realm
create_realm() {
    log_step "Creating realm: ${REALM}..."

    # Check if realm exists
    if kcadm get realms/${REALM} >/dev/null 2>&1; then
        log_warn "Realm ${REALM} already exists"
        return 0
    fi

    # Create realm
    kcadm create realms -s realm=${REALM} -s enabled=true \
        -s displayName="DevOps Platform" \
        -s registrationAllowed=false \
        -s loginWithEmailAllowed=true \
        -s duplicateEmailsAllowed=false \
        -s resetPasswordAllowed=true \
        -s editUsernameAllowed=false \
        -s bruteForceProtected=true \
        -s sslRequired=external

    log_info "Realm ${REALM} created"
}

# Create OIDC client
create_client() {
    local client_id="$1"
    local redirect_uri="$2"
    local public="${3:-false}"

    # Check if client exists
    local existing=$(kcadm get clients -r ${REALM} --fields id,clientId 2>/dev/null | grep "\"clientId\" : \"${client_id}\"" -B 1 | grep "\"id\"" | cut -d'"' -f4 || echo "")

    if [[ -n "$existing" ]]; then
        local client_secret=$(kcadm get clients/${existing}/client-secret -r ${REALM} 2>/dev/null | grep "value" | cut -d'"' -f4 || echo "")
        if [[ -n "$client_secret" ]]; then
            echo "${client_secret}"
            return 0
        fi
    fi

    # Generate client secret
    local client_secret=$(openssl rand -hex 32)

    # Create client (redirect output to stderr for logging)
    kcadm create clients -r ${REALM} \
        -s clientId=${client_id} \
        -s enabled=true \
        -s protocol=openid-connect \
        -s publicClient=${public} \
        -s standardFlowEnabled=true \
        -s directAccessGrantsEnabled=true \
        -s serviceAccountsEnabled=false \
        -s "redirectUris=[\"${redirect_uri}\"]" \
        -s 'webOrigins=["*"]' \
        -s secret="${client_secret}" \
        -s 'attributes={"post.logout.redirect.uris":"*"}' >&2

    echo "${client_secret}"
}

# Create groups
create_groups() {
    log_step "Creating groups..."

    for group in "devops-admins" "developers" "viewers"; do
        if kcadm get groups -r ${REALM} --fields name 2>/dev/null | grep -q "\"name\" : \"${group}\""; then
            log_warn "Group ${group} already exists"
            continue
        fi

        kcadm create groups -r ${REALM} -s name=${group}
        log_info "Created group: ${group}"
    done
}

# Configure groups client scope so group membership is included in tokens
configure_groups_scope() {
    log_step "Configuring groups client scope..."

    # Check if groups scope already exists
    local scope_id=$(kcadm get client-scopes -r ${REALM} --fields id,name 2>/dev/null | grep -B 1 "\"name\" : \"groups\"" | grep "\"id\"" | cut -d'"' -f4 || echo "")

    if [[ -z "$scope_id" ]]; then
        scope_id=$(kcadm create client-scopes -r ${REALM} \
            -s name=groups \
            -s protocol=openid-connect \
            -s 'attributes={"include.in.token.scope":"true","display.on.consent.screen":"true"}' -i 2>&1)
        log_info "Created groups client scope: ${scope_id}"

        # Add group membership protocol mapper
        kcadm create client-scopes/${scope_id}/protocol-mappers/models -r ${REALM} \
            -s name=groups \
            -s protocol=openid-connect \
            -s protocolMapper=oidc-group-membership-mapper \
            -s 'config={"full.path":"false","id.token.claim":"true","access.token.claim":"true","claim.name":"groups","userinfo.token.claim":"true"}' >/dev/null
        log_info "Added group membership mapper to groups scope"
    else
        log_warn "Groups client scope already exists"
    fi

    # Add as default realm scope
    kcadm update realms/${REALM}/default-default-client-scopes/${scope_id} -r ${REALM} 2>/dev/null || true

    # Add to each of our OIDC clients
    for client_name in "grafana" "argocd" "gitlab" "vault"; do
        local client_id=$(kcadm get clients -r ${REALM} --fields id,clientId 2>/dev/null | grep "\"clientId\" : \"${client_name}\"" -B 1 | grep "\"id\"" | cut -d'"' -f4 || echo "")
        if [[ -n "$client_id" ]]; then
            kcadm update clients/${client_id}/default-client-scopes/${scope_id} -r ${REALM} 2>/dev/null || true
        fi
    done
    log_info "Groups scope added to all OIDC clients"
}

# Create admin user
create_admin_user() {
    log_step "Creating admin users..."

    local secrets_file="${SCRIPT_DIR}/oidc-secrets.env"

    # Create devops-admin (temporary password)
    if kcadm get users -r ${REALM} -q username=devops-admin 2>/dev/null | grep -q "username"; then
        log_warn "User devops-admin already exists"
    else
        local temp_password=$(openssl rand -base64 12)

        kcadm create users -r ${REALM} \
            -s username=devops-admin \
            -s email=devops-admin@${DOMAIN} \
            -s enabled=true \
            -s emailVerified=true >/dev/null

        local user_id=$(kcadm get users -r ${REALM} -q username=devops-admin --fields id 2>/dev/null | grep "\"id\"" | cut -d'"' -f4)

        kcadm update users/${user_id}/reset-password -r ${REALM} \
            -s type=password \
            -s value="${temp_password}" \
            -s temporary=true -n

        kcadm update users/${user_id} -r ${REALM} -s 'requiredActions=[]'

        local group_id=$(kcadm get groups -r ${REALM} --fields id,name 2>/dev/null | grep -B 1 "devops-admins" | grep "\"id\"" | cut -d'"' -f4)
        if [[ -n "$group_id" ]]; then
            kcadm update users/${user_id}/groups/${group_id} -r ${REALM} -s userId=${user_id} -s groupId=${group_id} -n
        fi

        log_info "User created: devops-admin (temporary password)"
        echo "DEVOPS_ADMIN_PASSWORD=${temp_password}" >> "${secrets_file}"
    fi

    # Create platform-admin (permanent password for testing/admin access)
    if kcadm get users -r ${REALM} -q username=platform-admin 2>/dev/null | grep -q "username"; then
        log_warn "User platform-admin already exists"
    else
        # Generate shell-safe password (alphanumeric only to avoid kcadm escaping issues)
        local admin_password="Admin$(openssl rand -hex 4)"

        kcadm create users -r ${REALM} \
            -s username=platform-admin \
            -s email=platform-admin@${DOMAIN} \
            -s firstName=Platform \
            -s lastName=Administrator \
            -s enabled=true \
            -s emailVerified=true >/dev/null

        local user_id=$(kcadm get users -r ${REALM} -q username=platform-admin --fields id 2>/dev/null | grep "\"id\"" | cut -d'"' -f4)

        kcadm update users/${user_id}/reset-password -r ${REALM} \
            -s type=password \
            -s value="${admin_password}" \
            -s temporary=false -n

        kcadm update users/${user_id} -r ${REALM} -s 'requiredActions=[]'

        local group_id=$(kcadm get groups -r ${REALM} --fields id,name 2>/dev/null | grep -B 1 "devops-admins" | grep "\"id\"" | cut -d'"' -f4)
        if [[ -n "$group_id" ]]; then
            kcadm update users/${user_id}/groups/${group_id} -r ${REALM} -s userId=${user_id} -s groupId=${group_id} -n
        fi

        log_info "User created: platform-admin"
        log_info "Username: platform-admin"
        log_info "Password: ${admin_password}"
        echo "PLATFORM_ADMIN_PASSWORD=${admin_password}" >> "${secrets_file}"
    fi
}

# Configure all clients
configure_clients() {
    log_step "Configuring OIDC clients..."

    local secrets_file="${SCRIPT_DIR}/oidc-secrets.env"
    : > "${secrets_file}"
    chmod 600 "${secrets_file}"

    # Grafana
    log_info "Configuring Grafana OIDC client..."
    local grafana_secret=$(create_client "grafana" \
        "https://grafana.${DOMAIN}/login/generic_oauth")
    echo "GRAFANA_OIDC_SECRET=${grafana_secret}" >> "${secrets_file}"

    kubectl create secret generic grafana-oidc-secret -n monitoring \
        --from-literal=client-secret="${grafana_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # ArgoCD
    log_info "Configuring ArgoCD OIDC client..."
    local argocd_secret=$(create_client "argocd" \
        "https://argocd.${DOMAIN}/auth/callback")
    echo "ARGOCD_OIDC_SECRET=${argocd_secret}" >> "${secrets_file}"

    # Patch or create argocd-secret with OIDC client secret
    if kubectl get secret argocd-secret -n argocd >/dev/null 2>&1; then
        kubectl patch secret argocd-secret -n argocd \
            --type='json' \
            -p="[{'op': 'add', 'path': '/data/oidc.keycloak.clientSecret', 'value':'$(echo -n ${argocd_secret} | base64 -w0)'}]"
    else
        kubectl create secret generic argocd-secret -n argocd \
            --from-literal=oidc.keycloak.clientSecret="${argocd_secret}" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    # GitLab
    log_info "Configuring GitLab OIDC client..."
    local gitlab_secret=$(create_client "gitlab" \
        "https://gitlab.${DOMAIN}/users/auth/openid_connect/callback")
    echo "GITLAB_OIDC_SECRET=${gitlab_secret}" >> "${secrets_file}"

    # GitLab requires a specific format for OmniAuth provider configuration
    # Uses internal Keycloak URL for server-side endpoints (token, userinfo, jwks)
    # because *.localhost resolves to loopback inside pods (RFC 6761 / glibc)
    local KC_INTERNAL="http://keycloak-keycloakx-http.keycloak.svc.cluster.local"
    kubectl create secret generic gitlab-oidc-secret -n gitlab \
        --from-literal=provider="$(cat <<EOF
name: 'openid_connect'
label: 'Keycloak'
args:
  name: 'openid_connect'
  scope: ['openid', 'profile', 'email', 'groups']
  response_type: 'code'
  issuer: 'https://keycloak.${DOMAIN}/realms/devops'
  discovery: false
  client_auth_method: 'query'
  uid_field: 'preferred_username'
  client_options:
    identifier: 'gitlab'
    secret: '${gitlab_secret}'
    redirect_uri: 'https://gitlab.${DOMAIN}/users/auth/openid_connect/callback'
    authorization_endpoint: 'https://keycloak.${DOMAIN}/realms/devops/protocol/openid-connect/auth'
    token_endpoint: '${KC_INTERNAL}/realms/devops/protocol/openid-connect/token'
    userinfo_endpoint: '${KC_INTERNAL}/realms/devops/protocol/openid-connect/userinfo'
    jwks_uri: '${KC_INTERNAL}/realms/devops/protocol/openid-connect/certs'
    end_session_endpoint: 'https://keycloak.${DOMAIN}/realms/devops/protocol/openid-connect/logout'
EOF
)" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Vault
    log_info "Configuring Vault OIDC client..."
    local vault_secret=$(create_client "vault" \
        "https://vault.${DOMAIN}/ui/vault/auth/oidc/oidc/callback")
    echo "VAULT_OIDC_SECRET=${vault_secret}" >> "${secrets_file}"

    kubectl create secret generic vault-oidc-secret -n vault \
        --from-literal=client-id=vault \
        --from-literal=client-secret="${vault_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "Client secrets saved to: ${secrets_file}"
    log_info "Kubernetes secrets created in respective namespaces"

    # Restart services that mount OIDC secrets as volumes/env vars
    # ArgoCD watches argocd-secret natively (no restart needed)
    # Vault uses API-based OIDC config (no restart needed)
    log_info "Restarting services to pick up real OIDC secrets..."
    kubectl rollout restart deployment/prometheus-grafana -n monitoring 2>/dev/null || true
    kubectl rollout restart deployment/gitlab-webservice-default -n gitlab 2>/dev/null || true
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    echo "Keycloak Setup Complete!"
    echo "=============================================="
    echo ""
    echo "Realm: ${REALM}"
    echo "URL: https://keycloak.${DOMAIN}/realms/${REALM}"
    echo ""
    echo "Admin Console: https://keycloak.${DOMAIN}/admin/"
    echo "Realm Login: https://keycloak.${DOMAIN}/realms/${REALM}/account/"
    echo ""
    echo "Credentials saved to:"
    echo "  ${SCRIPT_DIR}/oidc-secrets.env"
    echo ""
    echo "Realm Users:"
    echo "  - platform-admin (permanent password, full admin access)"
    echo "  - devops-admin (temporary password, must change on first login)"
    echo ""
    echo "Services configured with SSO:"
    echo "  - Grafana: https://grafana.${DOMAIN}"
    echo "  - ArgoCD: https://argocd.${DOMAIN}"
    echo "  - GitLab: https://gitlab.${DOMAIN}"
    echo "  - Vault: https://vault.${DOMAIN}"
    echo ""
    echo "Testing SSO:"
    echo "  1. Open any service URL in a browser"
    echo "  2. Click 'Sign in with Keycloak' (or similar)"
    echo "  3. Log in with platform-admin credentials"
    echo "  4. You should be granted admin access to the service"
    echo ""
    echo "Next steps:"
    echo "  - Test SSO login to each service"
    echo "  - Create additional users in Keycloak admin console"
    echo "  - Assign users to appropriate groups (devops-admins/developers/viewers)"
    echo ""
}

# Main
main() {
    local action="${1:-all}"

    echo "=============================================="
    echo "Keycloak Setup"
    echo "Domain: ${DOMAIN}"
    echo "=============================================="

    # Wait for Keycloak to be ready
    log_info "Waiting for Keycloak to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloakx -n keycloak --timeout=300s

    # Login to admin CLI
    kcadm_login

    case "$action" in
        all)
            create_realm
            create_groups
            configure_clients
            configure_groups_scope
            create_admin_user
            print_summary
            ;;
        realm)
            create_realm
            ;;
        clients)
            configure_clients
            ;;
        user)
            create_admin_user
            ;;
        *)
            echo "Usage: $0 [all|realm|clients|user]"
            exit 1
            ;;
    esac
}

main "$@"
