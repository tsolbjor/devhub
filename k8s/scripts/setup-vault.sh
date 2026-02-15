#!/bin/bash
set -euo pipefail

# =============================================================================
# Vault Initialization and Configuration Script
# =============================================================================
# Run this after Vault pods are running to initialize and configure Vault.
#
# Usage: ./setup-vault.sh --env local|upcloud [all|init|unseal|configure|status]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
set -- "${ARGS[@]}"

setup_paths

# Vault uses HTTP internally (TLS at ingress)
VAULT_EXEC="kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200"

# Keys file stored per-environment
KEYS_FILE="${SCRIPT_ENV_DIR}/vault-init-keys.json"

# Check if Vault is already initialized
check_vault_status() {
    $VAULT_EXEC vault status 2>/dev/null || true
}

# Initialize Vault
init_vault() {
    log_step "Initializing Vault..."

    local status=$($VAULT_EXEC vault status -format=json 2>/dev/null || echo '{"initialized": false}')

    if echo "$status" | grep -q '"initialized": true'; then
        log_warn "Vault is already initialized"
        return 0
    fi

    log_info "Initializing Vault with 5 key shares, 3 threshold..."

    local init_output=$($VAULT_EXEC vault operator init -format=json)

    echo "$init_output" > "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"

    log_info "Vault initialized!"
    log_warn "IMPORTANT: Vault keys saved to ${KEYS_FILE}"
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

    if [[ ! -f "${KEYS_FILE}" ]]; then
        log_error "vault-init-keys.json not found at ${KEYS_FILE}"
        log_error "Run init first or provide unseal keys manually"
        exit 1
    fi

    local keys=$(cat "${KEYS_FILE}" | jq -r '.unseal_keys_b64[]' | head -3)

    for pod in vault-0 vault-1 vault-2; do
        log_info "Unsealing $pod..."
        for key in $keys; do
            kubectl exec -n vault $pod -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal "$key" 2>/dev/null || true
        done
    done

    log_info "Vault unsealed"
}

# Configure Kubernetes auth
configure_k8s_auth() {
    log_step "Configuring Kubernetes authentication..."

    if [[ ! -f "${KEYS_FILE}" ]]; then
        log_error "vault-init-keys.json not found at ${KEYS_FILE}"
        exit 1
    fi

    local root_token=$(cat "${KEYS_FILE}" | jq -r '.root_token')

    kubectl exec -n vault vault-0 -- sh -c "
        export VAULT_TOKEN='${root_token}'
        export VAULT_ADDR=http://127.0.0.1:8200
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

    local root_token=$(cat "${KEYS_FILE}" | jq -r '.root_token')

    kubectl exec -n vault vault-0 -- sh -c "
        export VAULT_TOKEN='${root_token}'
        export VAULT_ADDR=http://127.0.0.1:8200

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

    local root_token=$(cat "${KEYS_FILE}" | jq -r '.root_token')

    kubectl exec -n vault vault-0 -- sh -c "
        export VAULT_TOKEN='${root_token}'
        export VAULT_ADDR=http://127.0.0.1:8200

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
    echo "  ${KEYS_FILE}"
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
    echo "Vault Setup (${ENV})"
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
            echo "Usage: $0 --env local|upcloud [all|init|unseal|configure|status]"
            exit 1
            ;;
    esac
}

main "$@"
