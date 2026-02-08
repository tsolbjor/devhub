#!/bin/bash
set -euo pipefail

# =============================================================================
# Keycloak Realm and Client Configuration Script
# =============================================================================
# Creates the devops realm and configures OIDC clients for all services.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
DOMAIN="${DOMAIN:-devops.example.com}"
REALM="devops"

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

# Get Keycloak admin credentials
get_admin_token() {
    local password=$(kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.admin-password}' | base64 -d)
    local keycloak_url="https://keycloak.${DOMAIN}"
    
    local token=$(curl -s -X POST "${keycloak_url}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=admin" \
        -d "password=${password}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" | jq -r '.access_token')
    
    echo "$token"
}

# Create realm
create_realm() {
    log_step "Creating realm: ${REALM}..."
    
    local token=$(get_admin_token)
    local keycloak_url="https://keycloak.${DOMAIN}"
    
    # Check if realm exists
    local status=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        "${keycloak_url}/admin/realms/${REALM}")
    
    if [[ "$status" == "200" ]]; then
        log_warn "Realm ${REALM} already exists"
        return 0
    fi
    
    # Create realm
    curl -s -X POST "${keycloak_url}/admin/realms" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d @- <<EOF
{
    "realm": "${REALM}",
    "enabled": true,
    "displayName": "DevOps",
    "registrationAllowed": false,
    "loginWithEmailAllowed": true,
    "duplicateEmailsAllowed": false,
    "resetPasswordAllowed": true,
    "editUsernameAllowed": false,
    "bruteForceProtected": true,
    "sslRequired": "external"
}
EOF
    
    log_info "Realm ${REALM} created"
}

# Create OIDC client
create_client() {
    local client_id="$1"
    local redirect_uris="$2"
    local public="${3:-false}"
    
    log_info "Creating client: ${client_id}..."
    
    local token=$(get_admin_token)
    local keycloak_url="https://keycloak.${DOMAIN}"
    
    # Generate client secret
    local client_secret=$(openssl rand -hex 32)
    
    curl -s -X POST "${keycloak_url}/admin/realms/${REALM}/clients" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d @- <<EOF
{
    "clientId": "${client_id}",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": ${public},
    "standardFlowEnabled": true,
    "directAccessGrantsEnabled": true,
    "serviceAccountsEnabled": false,
    "redirectUris": ${redirect_uris},
    "webOrigins": ["+"],
    "secret": "${client_secret}",
    "attributes": {
        "post.logout.redirect.uris": "+"
    }
}
EOF
    
    echo "${client_secret}"
}

# Create groups
create_groups() {
    log_step "Creating groups..."
    
    local token=$(get_admin_token)
    local keycloak_url="https://keycloak.${DOMAIN}"
    
    for group in "devops-admins" "developers" "viewers"; do
        curl -s -X POST "${keycloak_url}/admin/realms/${REALM}/groups" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"${group}\"}" || true
        log_info "Created group: ${group}"
    done
}

# Create admin user
create_admin_user() {
    log_step "Creating admin user..."
    
    local token=$(get_admin_token)
    local keycloak_url="https://keycloak.${DOMAIN}"
    local password=$(openssl rand -base64 12)
    
    # Create user
    curl -s -X POST "${keycloak_url}/admin/realms/${REALM}/users" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d @- <<EOF
{
    "username": "devops-admin",
    "email": "admin@${DOMAIN}",
    "enabled": true,
    "emailVerified": true,
    "credentials": [{
        "type": "password",
        "value": "${password}",
        "temporary": true
    }]
}
EOF
    
    log_info "Admin user created"
    log_info "Username: devops-admin"
    log_info "Password: ${password} (temporary, must change on first login)"
}

# Configure all clients
configure_clients() {
    log_step "Configuring OIDC clients..."
    
    local secrets_file="${SCRIPT_DIR}/oidc-secrets.env"
    : > "${secrets_file}"
    chmod 600 "${secrets_file}"
    
    # Grafana
    local grafana_secret=$(create_client "grafana" \
        "[\"https://grafana.${DOMAIN}/login/generic_oauth\"]")
    echo "GRAFANA_OIDC_SECRET=${grafana_secret}" >> "${secrets_file}"
    
    # ArgoCD
    local argocd_secret=$(create_client "argocd" \
        "[\"https://argocd.${DOMAIN}/auth/callback\"]")
    echo "ARGOCD_OIDC_SECRET=${argocd_secret}" >> "${secrets_file}"
    
    # GitLab
    local gitlab_secret=$(create_client "gitlab" \
        "[\"https://gitlab.${DOMAIN}/users/auth/openid_connect/callback\"]")
    echo "GITLAB_OIDC_SECRET=${gitlab_secret}" >> "${secrets_file}"
    
    # Vault (if using OIDC auth)
    local vault_secret=$(create_client "vault" \
        "[\"https://vault.${DOMAIN}/ui/vault/auth/oidc/oidc/callback\", \"http://localhost:8250/oidc/callback\"]")
    echo "VAULT_OIDC_SECRET=${vault_secret}" >> "${secrets_file}"
    
    log_info "Client secrets saved to: ${secrets_file}"
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
    echo "Client secrets saved to:"
    echo "  ${SCRIPT_DIR}/oidc-secrets.env"
    echo ""
    echo "Next steps:"
    echo "  1. Update Grafana, ArgoCD, GitLab Helm values with client secrets"
    echo "  2. Re-deploy services to pick up SSO configuration"
    echo "  3. Create users and assign to groups"
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
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak -n keycloak --timeout=300s
    
    case "$action" in
        all)
            create_realm
            create_groups
            configure_clients
            create_admin_user
            print_summary
            ;;
        realm)
            create_realm
            ;;
        clients)
            configure_clients
            ;;
        *)
            echo "Usage: $0 [all|realm|clients]"
            exit 1
            ;;
    esac
}

main "$@"
