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

# Keys file stored per-environment (gitignored)
KEYS_FILE="${SCRIPT_ENV_DIR}/vault-init-keys.json"

# K8s secret used as a durable backup of the keys file.
# Stored in the vault namespace, never in git.
# On init: keys are written here automatically.
# On unseal: if the local file is missing, keys are restored from here.
KEYS_K8S_SECRET="vault-init-keys"
KEYS_K8S_NS="vault"

# Save keys JSON to the K8s secret (idempotent)
save_keys_to_k8s_secret() {
    local json_file="$1"
    kubectl create secret generic "${KEYS_K8S_SECRET}" \
        --namespace "${KEYS_K8S_NS}" \
        --from-file=vault-init-keys.json="${json_file}" \
        --save-config \
        --dry-run=client -o yaml \
        | kubectl apply -f - &>/dev/null
    log_info "Keys backed up to K8s secret ${KEYS_K8S_NS}/${KEYS_K8S_SECRET}"
}

# Restore keys JSON from the K8s secret into KEYS_FILE
restore_keys_from_k8s_secret() {
    if kubectl get secret "${KEYS_K8S_SECRET}" -n "${KEYS_K8S_NS}" &>/dev/null; then
        mkdir -p "$(dirname "${KEYS_FILE}")"
        kubectl get secret "${KEYS_K8S_SECRET}" -n "${KEYS_K8S_NS}" \
            -o jsonpath='{.data.vault-init-keys\.json}' \
            | base64 -d > "${KEYS_FILE}"
        chmod 600 "${KEYS_FILE}"
        log_info "Keys restored from K8s secret to ${KEYS_FILE}"
        return 0
    fi
    return 1
}

# Ensure the keys file is present, restoring from K8s secret if needed
require_keys_file() {
    if [[ ! -f "${KEYS_FILE}" ]]; then
        log_warn "Keys file not found locally — attempting restore from K8s secret..."
        if ! restore_keys_from_k8s_secret; then
            log_error "vault-init-keys.json not found and no K8s secret backup exists"
            log_error "Run './setup-vault.sh --env ${ENV} init' to re-initialize (WARNING: wipes all secrets)"
            exit 1
        fi
    fi
}

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

    mkdir -p "${SCRIPT_ENV_DIR}"
    echo "$init_output" > "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"

    # Back up to K8s secret so the keys survive even if the local file is lost
    save_keys_to_k8s_secret "${KEYS_FILE}"

    log_info "Vault initialized!"
    log_warn "Keys saved to ${KEYS_FILE} and backed up to K8s secret ${KEYS_K8S_NS}/${KEYS_K8S_SECRET}"

    echo ""
    echo "Unseal Keys (first 3 of 5):"
    echo "$init_output" | jq -r '.unseal_keys_b64[]' | head -3
    echo ""
    echo "Root Token:"
    echo "$init_output" | jq -r '.root_token'
    echo ""
}

# Unseal Vault
unseal_vault() {
    log_step "Unsealing Vault..."

    require_keys_file

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

    require_keys_file

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

    require_keys_file
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

    require_keys_file
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
    echo "Root token and unseal keys stored in two places:"
    echo "  Local:      ${KEYS_FILE}  (gitignored)"
    echo "  K8s secret: ${KEYS_K8S_NS}/${KEYS_K8S_SECRET}  (cluster-persistent)"
    echo ""
    echo "The K8s secret is the durable backup — if the local file is lost,"
    echo "re-running any setup-vault.sh command will restore it automatically."
    echo "For production use cloud KMS auto-unseal instead (see vault-autounseal-values.yaml)."
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
