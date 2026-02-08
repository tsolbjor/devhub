#!/bin/bash
set -euo pipefail

# =============================================================================
# Vault Initialization and Configuration Script
# =============================================================================
# Run this after Vault pods are running to initialize and configure Vault.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Check if Vault is already initialized
check_vault_status() {
    kubectl exec -n vault vault-0 -- vault status 2>/dev/null || true
}

# Initialize Vault
init_vault() {
    log_step "Initializing Vault..."
    
    local status=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null || echo '{"initialized": false}')
    
    if echo "$status" | grep -q '"initialized": true'; then
        log_warn "Vault is already initialized"
        return 0
    fi
    
    log_info "Initializing Vault with 5 key shares, 3 threshold..."
    
    # Initialize and save keys
    local init_output=$(kubectl exec -n vault vault-0 -- vault operator init -format=json)
    
    echo "$init_output" > "${SCRIPT_DIR}/vault-init-keys.json"
    chmod 600 "${SCRIPT_DIR}/vault-init-keys.json"
    
    log_info "Vault initialized!"
    log_warn "IMPORTANT: Vault keys saved to ${SCRIPT_DIR}/vault-init-keys.json"
    log_warn "Store these keys securely and delete this file!"
    
    echo ""
    echo "Unseal Keys:"
    echo "$init_output" | jq -r '.unseal_keys_b64[]' | head -3
    echo ""
    echo "Root Token:"
    echo "$init_output" | jq -r '.root_token'
    echo ""
}

# Unseal Vault
unseal_vault() {
    log_step "Unsealing Vault..."
    
    if [[ ! -f "${SCRIPT_DIR}/vault-init-keys.json" ]]; then
        log_error "vault-init-keys.json not found"
        log_error "Run init first or provide unseal keys manually"
        exit 1
    fi
    
    local keys=$(cat "${SCRIPT_DIR}/vault-init-keys.json" | jq -r '.unseal_keys_b64[]' | head -3)
    
    for pod in vault-0 vault-1 vault-2; do
        log_info "Unsealing $pod..."
        for key in $keys; do
            kubectl exec -n vault $pod -- vault operator unseal "$key" 2>/dev/null || true
        done
    done
    
    log_info "Vault unsealed"
}

# Configure Kubernetes auth
configure_k8s_auth() {
    log_step "Configuring Kubernetes authentication..."
    
    if [[ ! -f "${SCRIPT_DIR}/vault-init-keys.json" ]]; then
        log_error "vault-init-keys.json not found"
        exit 1
    fi
    
    local root_token=$(cat "${SCRIPT_DIR}/vault-init-keys.json" | jq -r '.root_token')
    
    # Enable Kubernetes auth
    kubectl exec -n vault vault-0 -- sh -c "
        export VAULT_TOKEN='${root_token}'
        vault auth enable kubernetes 2>/dev/null || true
        
        vault write auth/kubernetes/config \
            kubernetes_host=https://\$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT \
            kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        
        echo 'Kubernetes auth configured'
    "
    
    log_info "Kubernetes authentication enabled"
}

# Create role for external-secrets
create_external_secrets_role() {
    log_step "Creating role for External Secrets..."
    
    local root_token=$(cat "${SCRIPT_DIR}/vault-init-keys.json" | jq -r '.root_token')
    
    kubectl exec -n vault vault-0 -- sh -c "
        export VAULT_TOKEN='${root_token}'
        
        # Enable KV secrets engine v2
        vault secrets enable -path=secret kv-v2 2>/dev/null || true
        
        # Create policy
        vault policy write external-secrets - <<EOF
path \"secret/data/*\" {
  capabilities = [\"read\"]
}
EOF
        
        # Create role
        vault write auth/kubernetes/role/external-secrets \
            bound_service_account_names=external-secrets \
            bound_service_account_namespaces=external-secrets \
            policies=external-secrets \
            ttl=1h
        
        echo 'External Secrets role created'
    "
    
    log_info "External Secrets role created"
}

# Create example secret
create_example_secret() {
    log_step "Creating example secret..."
    
    local root_token=$(cat "${SCRIPT_DIR}/vault-init-keys.json" | jq -r '.root_token')
    
    kubectl exec -n vault vault-0 -- sh -c "
        export VAULT_TOKEN='${root_token}'
        
        vault kv put secret/example \
            username=admin \
            password=changeme123
        
        echo 'Example secret created at secret/example'
    "
    
    log_info "Example secret created: vault kv get secret/example"
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    echo "Vault Setup Complete!"
    echo "=============================================="
    echo ""
    echo "Root token and unseal keys saved to:"
    echo "  ${SCRIPT_DIR}/vault-init-keys.json"
    echo ""
    echo "IMPORTANT: Store these securely and delete the file!"
    echo ""
    echo "Next steps:"
    echo "  1. Apply ClusterSecretStore for External Secrets"
    echo "  2. Create secrets in Vault"
    echo "  3. Create ExternalSecret resources to sync to K8s"
    echo ""
    echo "Useful commands:"
    echo "  vault kv put secret/myapp key=value"
    echo "  vault kv get secret/myapp"
    echo ""
}

# Main
main() {
    local action="${1:-all}"
    
    echo "=============================================="
    echo "Vault Setup"
    echo "=============================================="
    
    case "$action" in
        all)
            init_vault
            unseal_vault
            configure_k8s_auth
            create_external_secrets_role
            create_example_secret
            print_summary
            ;;
        init)
            init_vault
            ;;
        unseal)
            unseal_vault
            ;;
        configure)
            configure_k8s_auth
            create_external_secrets_role
            ;;
        status)
            check_vault_status
            ;;
        *)
            echo "Usage: $0 [all|init|unseal|configure|status]"
            exit 1
            ;;
    esac
}

main "$@"
