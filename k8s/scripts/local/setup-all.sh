#!/bin/bash
set -euo pipefail

# =============================================================================
# Fully Automated Local Kubernetes Platform Setup
# =============================================================================
# This master script orchestrates all setup scripts to fully deploy the DevOps
# platform to a local Kubernetes cluster with ZERO manual intervention.
#
# Usage: ./setup-all.sh [--skip-post-config]
#
# Prerequisites:
#   - Rancher Desktop or similar local K8s with Kubernetes running
#   - kubectl, helm, openssl, jq, envsubst installed
#
# What this script does:
#   1. Generates CA and TLS certificates (setup-ca.sh)
#   2. Sets up nginx-ingress controller (setup-cluster.sh)
#   3. Deploys all DevOps components (deploy.sh)
#   4. Waits for Vault, initializes, unseals, and configures it
#   5. Waits for Keycloak and configures realm/clients
#   6. Waits for GitLab to be fully ready
#   7. Bootstraps ArgoCD app-of-apps
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../.."
OVERLAY_DIR="${K8S_DIR}/overlays/local"
CERTS_DIR="${K8S_DIR}/certs"

# Parse config for domain
DOMAIN=$(grep -E '^domain:' "${OVERLAY_DIR}/config.yaml" | sed 's/domain:[[:space:]]*//')
export DOMAIN

# Flags
SKIP_POST_CONFIG=false

for arg in "$@"; do
    case "$arg" in
        --skip-post-config)
            SKIP_POST_CONFIG=true
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_phase() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  PHASE: $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# =============================================================================
# Requirement Checks
# =============================================================================

check_all_requirements() {
    log_step "Checking all requirements..."
    
    local missing=()
    
    command -v kubectl &>/dev/null || missing+=("kubectl")
    command -v helm &>/dev/null || missing+=("helm")
    command -v openssl &>/dev/null || missing+=("openssl")
    command -v jq &>/dev/null || missing+=("jq")
    command -v envsubst &>/dev/null || missing+=("envsubst (gettext)")
    command -v curl &>/dev/null || missing+=("curl")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
    
    # Check Kubernetes connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        log_error "Make sure Rancher Desktop (or your K8s) is running."
        exit 1
    fi
    
    log_info "All requirements satisfied"
}

# =============================================================================
# Phase 1: Certificates
# =============================================================================

phase_certificates() {
    log_phase "1/7 - Certificate Generation"
    
    if [[ -f "${CERTS_DIR}/domains/local-dev.crt" && -f "${CERTS_DIR}/ca/ca.crt" ]]; then
        log_info "Certificates already exist, skipping generation"
        log_info "Delete ${CERTS_DIR} to regenerate"
    else
        log_step "Generating CA and TLS certificates..."
        "${SCRIPT_DIR}/setup-ca.sh"
    fi
}

# =============================================================================
# Phase 2: Cluster Setup (Ingress Controller)
# =============================================================================

phase_cluster_setup() {
    log_phase "2/7 - Cluster Setup (nginx-ingress)"
    
    # Check if ingress-nginx already installed
    if helm list -n ingress-nginx 2>/dev/null | grep -q ingress-nginx; then
        log_info "nginx-ingress already installed"
    else
        log_step "Running cluster setup..."
        "${SCRIPT_DIR}/setup-cluster.sh"
    fi
}

# =============================================================================
# Phase 3: Deploy DevOps Platform
# =============================================================================

phase_deploy() {
    log_phase "3/7 - Deploy DevOps Platform"
    
    log_step "Deploying all DevOps components..."
    "${SCRIPT_DIR}/deploy.sh" local all deploy
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
            # Pod is running, but might not be ready to accept commands yet
            sleep 5
            log_info "Vault pods are running"
            return 0
        fi
        
        ((attempt++))
        echo -n "."
        sleep 5
    done
    
    log_error "Vault pods did not become ready within timeout"
    return 1
}

phase_vault() {
    log_phase "4/7 - Vault Initialization & Configuration"
    
    wait_for_vault_pods
    
    # Check if Vault is already initialized
    local status=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null || echo '{"initialized": false, "sealed": true}')
    local is_initialized=$(echo "$status" | jq -r '.initialized')
    local is_sealed=$(echo "$status" | jq -r '.sealed')
    
    if [[ "$is_initialized" == "true" ]]; then
        log_info "Vault is already initialized"
        
        # If sealed and we have keys, unseal
        if [[ "$is_sealed" == "true" && -f "${SCRIPT_DIR}/vault-init-keys.json" ]]; then
            log_step "Unsealing Vault..."
            "${SCRIPT_DIR}/setup-vault.sh" unseal
        elif [[ "$is_sealed" == "true" ]]; then
            log_warn "Vault is sealed but no keys found at ${SCRIPT_DIR}/vault-init-keys.json"
            log_warn "Manual unseal required - continuing with other setup"
            return 0
        fi
        
        # Configure if not already done
        log_step "Configuring Vault..."
        "${SCRIPT_DIR}/setup-vault.sh" configure || true
    else
        log_step "Running full Vault setup (init, unseal, configure)..."
        "${SCRIPT_DIR}/setup-vault.sh" all
    fi
    
    log_info "Vault setup complete"
}

# =============================================================================
# Phase 5: Configure Keycloak (Realm + Clients)
# =============================================================================

wait_for_keycloak() {
    log_step "Waiting for Keycloak to be ready..."
    
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=keycloakx \
        -n keycloak \
        --timeout=600s || {
            log_error "Keycloak did not become ready"
            return 1
        }

    # Additional wait for Keycloak to fully start (REST API needs more time)
    # Note: keycloakx image doesn't have curl, so we use kcadm.sh as a health check
    log_info "Waiting for Keycloak REST API..."
    local max_attempts=30
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if kubectl exec -n keycloak keycloak-keycloakx-0 -- \
            /opt/keycloak/bin/kcadm.sh get realms/master --server http://localhost:8080 --realm master &>/dev/null; then
            log_info "Keycloak API is ready"
            return 0
        fi

        ((attempt++))
        echo -n "."
        sleep 10
    done

    log_warn "Keycloak API check timed out, proceeding anyway..."
    return 0
}

phase_keycloak() {
    log_phase "5/7 - Keycloak Configuration"
    
    wait_for_keycloak
    
    # Check if realm already exists
    log_step "Configuring Keycloak realm and OIDC clients..."
    
    # Export domain for setup-keycloak.sh
    export DOMAIN
    "${SCRIPT_DIR}/setup-keycloak.sh" all || {
        log_warn "Keycloak configuration had issues - may need manual review"
    }
    
    log_info "Keycloak configuration complete"
}

# =============================================================================
# Phase 6: Wait for GitLab
# =============================================================================

phase_gitlab() {
    log_phase "6/7 - GitLab Readiness Check"
    
    log_step "Waiting for GitLab to be ready (this can take 15-30 minutes)..."
    
    # GitLab has many components - we wait for the main webservice
    local max_attempts=120  # 20 minutes (120 * 10 seconds)
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        local ready=$(kubectl get pods -n gitlab -l app=webservice -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        
        if [[ "$ready" == "True" ]]; then
            log_info "GitLab is ready"
            break
        fi
        
        ((attempt++))
        if [[ $((attempt % 12)) -eq 0 ]]; then
            local elapsed=$((attempt * 10 / 60))
            log_info "Still waiting for GitLab... (${elapsed} minutes elapsed)"
        fi
        sleep 10
    done
    
    if [[ $attempt -ge $max_attempts ]]; then
        log_warn "GitLab did not become ready within timeout"
        log_warn "GitLab may still be starting - check with: kubectl get pods -n gitlab"
    else
        log_info "GitLab is ready"
    fi
}

# =============================================================================
# Phase 7: Bootstrap ArgoCD App-of-Apps
# =============================================================================

phase_argocd_bootstrap() {
    log_phase "7/7 - ArgoCD App-of-Apps Bootstrap"
    
    log_step "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=argocd-server \
        -n argocd \
        --timeout=300s || {
            log_error "ArgoCD did not become ready"
            return 1
        }
    
    log_step "Bootstrapping ArgoCD app-of-apps..."
    "${SCRIPT_DIR}/deploy.sh" local bootstrap deploy
    
    log_info "ArgoCD app-of-apps bootstrapped"
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
    echo "Environment: local"
    echo "Domain: ${DOMAIN}"
    echo ""
    echo "DevOps Platform URLs:"
    echo "  • Keycloak:   https://keycloak.${DOMAIN}"
    echo "  • Vault:      https://vault.${DOMAIN}"
    echo "  • Grafana:    https://grafana.${DOMAIN}"
    echo "  • Prometheus: https://prometheus.${DOMAIN}"
    echo "  • GitLab:     https://gitlab.${DOMAIN}"
    echo "  • ArgoCD:     https://argocd.${DOMAIN}"
    echo ""
    echo "Credentials (retrieve from secrets):"
    echo "  Keycloak Admin:"
    echo "    kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.admin-password}' | base64 -d"
    echo ""
    echo "  Grafana Admin:"
    echo "    kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d"
    echo ""
    echo "  ArgoCD Admin:"
    echo "    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    echo "  GitLab Root:"
    echo "    kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    if [[ -f "${SCRIPT_DIR}/vault-init-keys.json" ]]; then
        echo "  Vault Root Token:"
        echo "    cat ${SCRIPT_DIR}/vault-init-keys.json | jq -r '.root_token'"
        echo ""
        echo "  ⚠️  IMPORTANT: Secure vault-init-keys.json and delete after backup!"
    fi
    echo ""
    if [[ -f "${SCRIPT_DIR}/oidc-secrets.env" ]]; then
        echo "  OIDC Client Secrets:"
        echo "    cat ${SCRIPT_DIR}/oidc-secrets.env"
    fi
    echo ""
    echo "For Windows browser access (run as Admin in PowerShell):"
    echo "  cd k8s\\scripts\\windows && .\\setup-all.ps1"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Fully Automated Local Kubernetes Platform Setup${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "This will set up the complete DevOps platform with zero manual steps."
    echo "Estimated time: 20-40 minutes (depending on GitLab)"
    echo ""
    
    check_all_requirements
    
    phase_certificates
    phase_cluster_setup
    phase_deploy
    
    if [[ "$SKIP_POST_CONFIG" == "false" ]]; then
        phase_vault
        phase_keycloak
        phase_gitlab
        phase_argocd_bootstrap
    else
        log_warn "Skipping post-deployment configuration (--skip-post-config)"
    fi
    
    print_final_summary
}

main "$@"
