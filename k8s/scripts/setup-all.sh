#!/bin/bash
set -euo pipefail

# =============================================================================
# Fully Automated Kubernetes Platform Setup
# =============================================================================
# Orchestrates all setup scripts to fully deploy the DevOps platform
# with ZERO manual intervention.
#
# Usage: ./setup-all.sh --env local|upcloud [--skip-post-config]
#
# Prerequisites:
#   - local: Rancher Desktop or similar local K8s with Kubernetes running
#   - upcloud: kubectl configured for UpCloud managed K8s
#   - kubectl, helm, openssl, jq, envsubst installed
#
# What this script does:
#   1. Generates CA and TLS certificates (local only)
#   2. Sets up cluster prerequisites (Envoy Gateway is installed by deploy.sh)
#   3. Deploys all DevOps components
#   4. Waits for Vault, initializes, unseals, and configures it
#   5. Waits for Keycloak and configures realm/clients
#   6. Waits for Forgejo to be fully ready
#   7. Moves platform credentials into Vault (External Secrets takes over)
#   8. Bootstraps ArgoCD app-of-apps and hands the platform over to GitOps
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Extract --skip-post-config before parse_env_arg eats it
SKIP_POST_CONFIG=false
FILTERED_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --skip-post-config) SKIP_POST_CONFIG=true ;;
        *) FILTERED_ARGS+=("$arg") ;;
    esac
done

parse_env_arg "${FILTERED_ARGS[@]}"
setup_paths
parse_config
use_env_kubeconfig

# =============================================================================
# Phase 1: Certificates (local only)
# =============================================================================

phase_certificates() {
    log_phase "1/8 - Certificate Generation"

    if [[ "$ENV" != "local" ]]; then
        log_info "Skipping certificate generation (not needed for ${ENV})"
        return 0
    fi

    if [[ -f "${CERTS_DIR}/domains/local-dev.crt" && -f "${CERTS_DIR}/ca/ca.crt" ]]; then
        log_info "Certificates already exist, skipping generation"
        log_info "Delete ${CERTS_DIR} to regenerate"
    else
        log_step "Generating CA and TLS certificates..."
        "${SCRIPT_DIR}/setup-ca.sh" --env "${ENV}"
    fi
}

# =============================================================================
# Phase 2: Cluster Setup (Ingress Controller)
# =============================================================================

phase_cluster_setup() {
    log_phase "2/8 - Cluster Setup (nginx-ingress)"

    if helm list -n ingress-nginx 2>/dev/null | grep -q ingress-nginx; then
        log_info "nginx-ingress already installed"
    else
        log_step "Running cluster setup..."
        "${SCRIPT_DIR}/setup-cluster.sh" --env "${ENV}"
    fi
}

# =============================================================================
# Phase 3: Deploy DevOps Platform
# =============================================================================

phase_deploy() {
    log_phase "3/8 - Deploy DevOps Platform"

    log_step "Deploying all DevOps components..."
    "${SCRIPT_DIR}/deploy.sh" --env "${ENV}" all deploy
}

# =============================================================================
# Phase 4: Configure Vault (Init + Unseal + Configure)
# =============================================================================

wait_for_vault_pods() {
    log_step "Waiting for Vault pods to be ready..."

    local max_attempts=60
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        local ready=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

        if [[ "$ready" == "Running" ]]; then
            sleep 5
            log_info "Vault pods are running"
            return 0
        fi

        ((attempt++)) || true
        echo -n "."
        sleep 5
    done

    log_error "Vault pods did not become ready within timeout"
    return 1
}

phase_vault() {
    log_phase "4/8 - Vault Initialization & Configuration"

    wait_for_vault_pods

    local KEYS_FILE="${SCRIPT_ENV_DIR}/vault-init-keys.json"
    local status=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null || echo '{"initialized": false, "sealed": true}')
    local is_initialized=$(echo "$status" | jq -r '.initialized')
    local is_sealed=$(echo "$status" | jq -r '.sealed')

    if [[ "$is_initialized" == "true" ]]; then
        log_info "Vault is already initialized"

        if [[ "$is_sealed" == "true" && -f "${KEYS_FILE}" ]]; then
            log_step "Unsealing Vault..."
            "${SCRIPT_DIR}/setup-vault.sh" --env "${ENV}" unseal
        elif [[ "$is_sealed" == "true" ]]; then
            log_warn "Vault is sealed but no keys found at ${KEYS_FILE}"
            log_warn "Manual unseal required - continuing with other setup"
            return 0
        fi

        log_step "Configuring Vault..."
        "${SCRIPT_DIR}/setup-vault.sh" --env "${ENV}" configure || true
    else
        log_step "Running full Vault setup (init, unseal, configure)..."
        "${SCRIPT_DIR}/setup-vault.sh" --env "${ENV}" all
    fi

    log_info "Vault setup complete"
}

# =============================================================================
# Phase 5: Configure Keycloak (Realm + Clients)
# =============================================================================

wait_for_keycloak() {
    log_step "Waiting for Keycloak to be ready..."

    kubectl wait --for=condition=ready pod \
        -l app=keycloak \
        -n keycloak \
        --timeout=600s || {
            log_error "Keycloak did not become ready"
            return 1
        }

    log_info "Waiting for Keycloak REST API..."
    local max_attempts=30
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        local output
        output=$(kubectl exec -n keycloak keycloak-0 -- \
            /opt/keycloak/bin/kcadm.sh get realms/master --server http://localhost:8080 --realm master 2>&1) || true
        if echo "$output" | grep -q "HTTP"; then
            log_info "Keycloak API is ready"
            return 0
        fi

        ((attempt++)) || true
        echo -n "."
        sleep 10
    done

    log_warn "Keycloak API check timed out, proceeding anyway..."
    return 0
}

phase_keycloak() {
    log_phase "5/8 - Keycloak Configuration"

    wait_for_keycloak

    log_step "Configuring Keycloak realm and OIDC clients..."

    "${SCRIPT_DIR}/setup-keycloak.sh" --env "${ENV}" all || {
        log_warn "Keycloak configuration had issues - may need manual review"
    }

    log_info "Keycloak configuration complete"
}

# =============================================================================
# Phase 6: Wait for Forgejo
# =============================================================================

phase_forgejo() {
    log_phase "6/8 - Forgejo Readiness Check"

    log_step "Waiting for Forgejo to be ready..."

    local max_attempts=120
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        local ready=$(kubectl get pods -n forgejo -l app.kubernetes.io/name=forgejo \
            -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

        if [[ "$ready" == "True" ]]; then
            log_info "Forgejo is ready"
            break
        fi

        ((attempt++)) || true
        if [[ $((attempt % 12)) -eq 0 ]]; then
            local elapsed=$((attempt * 10 / 60))
            log_info "Still waiting for Forgejo... (${elapsed} minutes elapsed)"
        fi
        sleep 10
    done

    if [[ $attempt -ge $max_attempts ]]; then
        log_warn "Forgejo did not become ready within timeout"
        log_warn "Check with: kubectl get pods -n forgejo"
    else
        log_info "Forgejo is ready"
    fi
}

# =============================================================================
# Phase 7: Platform credentials → Vault
# =============================================================================

phase_platform_secrets() {
    log_phase "7/8 - Platform Secrets → Vault"

    log_step "Waiting for External Secrets Operator..."
    kubectl wait --for=condition=available deploy \
        -l app.kubernetes.io/name=external-secrets \
        -n external-secrets --timeout=300s || {
            log_warn "External Secrets Operator not ready — skipping the handover"
            return 0
        }

    "${SCRIPT_DIR}/deploy.sh" --env "${ENV}" platform-secrets deploy || {
        log_warn "Platform secret handover incomplete — run it again later:"
        log_warn "  ./deploy.sh --env ${ENV} platform-secrets"
    }
}

# =============================================================================
# Phase 8: Bootstrap ArgoCD App-of-Apps + GitOps handover
# =============================================================================

phase_argocd_bootstrap() {
    log_phase "8/8 - ArgoCD Bootstrap & GitOps Handover"

    log_step "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=argocd-server \
        -n argocd \
        --timeout=300s || {
            log_error "ArgoCD did not become ready"
            return 1
        }

    log_step "Bootstrapping ArgoCD app-of-apps..."
    "${SCRIPT_DIR}/deploy.sh" --env "${ENV}" bootstrap deploy

    # Hand the non-bootstrap components over so drift is corrected automatically
    # instead of requiring another deploy.sh run.
    log_step "Handing platform components over to ArgoCD..."
    "${SCRIPT_DIR}/deploy.sh" --env "${ENV}" gitops deploy || {
        log_warn "GitOps handover incomplete — run it again later:"
        log_warn "  ./deploy.sh --env ${ENV} gitops"
    }

    log_info "ArgoCD bootstrap complete"
}

# =============================================================================
# Summary
# =============================================================================

print_final_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SETUP COMPLETE!${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Environment: ${ENV}"
    echo "Domain: ${DOMAIN}"
    echo ""
    echo "DevOps Platform URLs:"
    echo "  - Keycloak:   https://keycloak.${DOMAIN}"
    echo "  - Vault:      https://vault.${DOMAIN}"
    echo "  - Grafana:    https://grafana.${DOMAIN}"
    echo "  - Prometheus: https://prometheus.${DOMAIN}"
    echo "  - Forgejo:    https://git.${DOMAIN}"
    echo "  - ArgoCD:     https://argocd.${DOMAIN}"
    echo ""
    echo "Credentials (retrieve from secrets):"
    echo "  Keycloak Admin:"
    echo "    kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    echo "  Grafana Admin:"
    echo "    kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d"
    echo ""
    echo "  ArgoCD Admin:"
    echo "    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    echo "  Forgejo Admin:"
    echo "    kubectl get secret forgejo-admin-secret -n forgejo -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    local KEYS_FILE="${SCRIPT_ENV_DIR}/vault-init-keys.json"
    if [[ -f "${KEYS_FILE}" ]]; then
        echo "  Vault key material: ${KEYS_FILE}"
        echo "    The initial root token has been revoked; a platform-admin token in"
        echo "    this file replaces it. Renew it with:"
        echo "      ./setup-vault.sh --env ${ENV} renew-admin"
        echo ""
        echo "  IMPORTANT: move this file to offline storage. It is the only copy —"
        echo "  it is deliberately not stored in the cluster."
    fi
    echo ""
    local secrets_file="${SCRIPT_ENV_DIR}/oidc-secrets.env"
    if [[ -f "${secrets_file}" ]]; then
        echo "  OIDC Client Secrets:"
        echo "    cat ${secrets_file}"
    fi
    echo ""
    if [[ "$ENV" == "local" ]]; then
        echo "For Windows browser access (run as Admin in PowerShell):"
        echo "  cd k8s\\scripts\\windows && .\\setup-all.ps1"
    fi
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Fully Automated Kubernetes Platform Setup (${ENV})${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "This will set up the complete DevOps platform with zero manual steps."
    echo "Estimated time: 15-25 minutes"
    echo ""

    check_all_requirements

    phase_certificates
    phase_cluster_setup
    phase_deploy

    if [[ "$SKIP_POST_CONFIG" == "false" ]]; then
        phase_vault
        phase_keycloak
        phase_forgejo
        phase_platform_secrets
        phase_argocd_bootstrap
    else
        log_warn "Skipping post-deployment configuration (--skip-post-config)"
    fi

    print_final_summary
}

main
