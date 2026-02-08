#!/bin/bash
set -euo pipefail

# =============================================================================
# Unified Kubernetes Deploy Script
# =============================================================================
# Deploys applications and DevOps platform to local or UpCloud environments.
#
# Usage: ./deploy.sh [local|upcloud] [component] [action]
#
# Components: all, apps, devops, or specific services
# Actions: deploy (default), status, delete
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../.."
BASE_DIR="${K8S_DIR}/base"

# Defaults
ENV="${1:-local}"
COMPONENT="${2:-all}"
ACTION="${3:-deploy}"

# Environment-specific configuration
case "$ENV" in
    local)
        DOMAIN="local.dev"
        CERTS_DIR="${K8S_DIR}/certs"
        OVERLAY_DIR="${K8S_DIR}/overlays/local"
        USE_CERT_MANAGER=false
        ;;
    upcloud)
        DOMAIN="${DOMAIN:-devops.example.com}"
        OVERLAY_DIR="${K8S_DIR}/overlays/upcloud"
        USE_CERT_MANAGER=true
        ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"
        ;;
    *)
        echo "Usage: $0 [local|upcloud] [component] [action]"
        echo ""
        echo "Environments:"
        echo "  local   - WSL/Rancher Desktop with local CA"
        echo "  upcloud - UpCloud managed K8s with Let's Encrypt"
        echo ""
        echo "Components:"
        echo "  all        - Deploy everything (apps + devops)"
        echo "  apps       - Application services only"
        echo "  devops     - DevOps platform only"
        echo "  keycloak, vault, monitoring, gitlab, argocd - Individual devops components"
        echo ""
        echo "Actions:"
        echo "  deploy     - Deploy (default)"
        echo "  status     - Show status"
        echo "  delete     - Delete resources"
        exit 1
        ;;
esac

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

# =============================================================================
# Common Functions
# =============================================================================

# Template overlay values with environment variables
# Usage: template_values <overlay-file> <output-file>
template_values() {
    local input="$1"
    local output="$2"
    envsubst < "$input" > "$output"
}

# Get Helm values args for a component (base + templated overlay)
# Usage: get_values_args <component>
get_values_args() {
    local component="$1"
    local base_values="${BASE_DIR}/devops/${component}/values.yaml"
    local overlay_values="${OVERLAY_DIR}/devops/${component}/values.yaml"
    local templated_values="/tmp/${component}-overlay-values.yaml"
    
    local args=""
    
    # Base values (if exists)
    if [[ -f "$base_values" ]]; then
        args="-f $base_values"
    fi
    
    # Overlay values (template and add if exists)
    if [[ -f "$overlay_values" ]]; then
        template_values "$overlay_values" "$templated_values"
        args="$args -f $templated_values"
    fi
    
    echo "$args"
}

check_requirements() {
    log_info "Checking requirements..."
    command -v kubectl &>/dev/null || { log_error "kubectl required"; exit 1; }
    command -v envsubst &>/dev/null || { log_error "envsubst required (install gettext)"; exit 1; }
    kubectl cluster-info &>/dev/null || { log_error "Cannot connect to cluster"; exit 1; }
    
    if [[ "$ENV" == "local" && ! -f "${CERTS_DIR}/domains/local-dev.crt" ]]; then
        log_error "Certificates not found. Run: ./setup-ca.sh"
        exit 1
    fi
    
    log_info "Requirements satisfied (env: $ENV)"
}

add_helm_repos() {
    command -v helm &>/dev/null || { log_error "helm required"; exit 1; }
    
    log_step "Adding Helm repositories..."
    
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
    helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo add gitlab https://charts.gitlab.io 2>/dev/null || true
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    
    helm repo update
    log_info "Helm repositories updated"
}

# =============================================================================
# Apps Deployment
# =============================================================================

deploy_apps() {
    log_step "Deploying applications..."
    
    # Apply apps overlay
    kubectl apply -k "${OVERLAY_DIR}/apps"
    
    # Wait for pods
    kubectl wait --for=condition=ready pod --all --namespace tshub --timeout=300s 2>/dev/null || \
        log_warn "Some pods may not be ready yet"
    
    log_info "Applications deployed"
}

delete_apps() {
    log_step "Deleting applications..."
    kubectl delete -k "${OVERLAY_DIR}/apps" 2>/dev/null || true
    log_info "Applications deleted"
}

status_apps() {
    log_step "Application Status:"
    echo ""
    echo "Pods:"
    kubectl get pods -n tshub -o wide 2>/dev/null || echo "  No pods found"
    echo ""
    echo "Services:"
    kubectl get svc -n tshub 2>/dev/null || echo "  No services found"
    echo ""
    echo "Ingress:"
    kubectl get ingress -n tshub 2>/dev/null || echo "  No ingress found"
}

# =============================================================================
# DevOps Platform Deployment
# =============================================================================

create_devops_namespaces() {
    log_step "Creating DevOps namespaces..."
    kubectl apply -f "${BASE_DIR}/devops/namespaces/namespaces.yaml"
    log_info "Namespaces created"
}

copy_tls_secrets() {
    if [[ "$ENV" != "local" ]]; then return 0; fi
    
    log_step "Copying TLS secrets to namespaces..."
    
    local CERT_B64=$(base64 -w 0 "${CERTS_DIR}/domains/local-dev.crt")
    local KEY_B64=$(base64 -w 0 "${CERTS_DIR}/domains/local-dev.key")
    
    for ns in keycloak vault gitlab argocd monitoring tshub; do
        kubectl create namespace "$ns" 2>/dev/null || true
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: local-tls-secret
  namespace: ${ns}
type: kubernetes.io/tls
data:
  tls.crt: ${CERT_B64}
  tls.key: ${KEY_B64}
EOF
    done
    
    log_info "TLS secrets distributed"
}

install_cert_manager() {
    if [[ "$ENV" == "local" ]]; then
        log_info "Skipping cert-manager (using local CA)"
        return 0
    fi
    
    log_step "Installing cert-manager..."
    
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        -f "${BASE_DIR}/devops/cert-manager/values.yaml" \
        --wait --timeout 5m
    
    kubectl wait --for=condition=ready pod -l app=webhook -n cert-manager --timeout=60s
    
    # Apply cluster issuers with templated email
    envsubst < "${BASE_DIR}/devops/cert-manager/cluster-issuers.yaml" | kubectl apply -f -
    
    log_info "cert-manager installed"
}

install_keycloak() {
    log_step "Installing Keycloak..."
    
    kubectl create namespace keycloak 2>/dev/null || true
    
    if ! kubectl get secret keycloak-admin-secret -n keycloak &>/dev/null; then
        kubectl create secret generic keycloak-admin-secret -n keycloak \
            --from-literal=admin-password="$(openssl rand -base64 24)"
    fi
    
    if ! kubectl get secret keycloak-postgresql-secret -n keycloak &>/dev/null; then
        kubectl create secret generic keycloak-postgresql-secret -n keycloak \
            --from-literal=postgres-password="$(openssl rand -base64 24)" \
            --from-literal=password="$(openssl rand -base64 24)"
    fi
    
    local values_args=$(get_values_args "keycloak")
    
    helm upgrade --install keycloak bitnami/keycloak \
        --namespace keycloak \
        $values_args \
        --wait --timeout 10m
    
    log_info "Keycloak installed"
}

install_vault() {
    log_step "Installing Vault..."
    
    kubectl create namespace vault 2>/dev/null || true
    
    local values_args=$(get_values_args "vault")
    
    helm upgrade --install vault hashicorp/vault \
        --namespace vault \
        $values_args \
        --wait --timeout 5m
    
    log_info "Vault installed"
    log_warn "Initialize Vault: kubectl exec -n vault vault-0 -- vault operator init"
}

install_external_secrets() {
    log_step "Installing External Secrets..."
    
    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets \
        --create-namespace \
        -f "${BASE_DIR}/devops/external-secrets/values.yaml" \
        --wait --timeout 5m
    
    log_info "External Secrets installed"
}

install_monitoring() {
    log_step "Installing monitoring stack..."
    
    kubectl create namespace monitoring 2>/dev/null || true
    
    if ! kubectl get secret grafana-admin-secret -n monitoring &>/dev/null; then
        kubectl create secret generic grafana-admin-secret -n monitoring \
            --from-literal=admin-user=admin \
            --from-literal=admin-password="$(openssl rand -base64 24)"
    fi
    
    # Prometheus stack uses monitoring overlay
    local base_values="${BASE_DIR}/devops/monitoring/prometheus-stack-values.yaml"
    local overlay_values="${OVERLAY_DIR}/devops/monitoring/values.yaml"
    local templated_values="/tmp/monitoring-overlay-values.yaml"
    
    local prom_args="-f $base_values"
    if [[ -f "$overlay_values" ]]; then
        template_values "$overlay_values" "$templated_values"
        prom_args="$prom_args -f $templated_values"
    fi
    
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        $prom_args \
        --wait --timeout 10m
    
    helm upgrade --install loki grafana/loki \
        --namespace monitoring \
        -f "${BASE_DIR}/devops/monitoring/loki-values.yaml" \
        --wait --timeout 10m
    
    helm upgrade --install tempo grafana/tempo \
        --namespace monitoring \
        -f "${BASE_DIR}/devops/monitoring/tempo-values.yaml" \
        --wait --timeout 5m
    
    helm upgrade --install promtail grafana/promtail \
        --namespace monitoring \
        -f "${BASE_DIR}/devops/monitoring/promtail-values.yaml" \
        --wait --timeout 5m
    
    log_info "Monitoring stack installed"
}

install_gitlab() {
    log_step "Installing GitLab CE..."
    
    kubectl create namespace gitlab 2>/dev/null || true
    
    local values_args=$(get_values_args "gitlab")
    
    helm upgrade --install gitlab gitlab/gitlab \
        --namespace gitlab \
        $values_args \
        --timeout 30m
    
    log_info "GitLab installing (10-20 minutes)"
}

install_argocd() {
    log_step "Installing ArgoCD..."
    
    kubectl create namespace argocd 2>/dev/null || true
    
    local values_args=$(get_values_args "argocd")
    
    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        $values_args \
        --wait --timeout 5m
    
    log_info "ArgoCD installed"
}

apply_devops_ingress() {
    log_step "Applying DevOps ingress..."
    kubectl apply -k "${OVERLAY_DIR}/devops"
    log_info "DevOps ingress applied"
}

deploy_devops() {
    add_helm_repos
    create_devops_namespaces
    [[ "$ENV" == "local" ]] && copy_tls_secrets
    install_cert_manager
    install_keycloak
    install_vault
    install_external_secrets
    install_monitoring
    install_gitlab
    install_argocd
    apply_devops_ingress
}

delete_devops() {
    log_step "Deleting DevOps platform..."
    
    helm uninstall argocd -n argocd 2>/dev/null || true
    helm uninstall gitlab -n gitlab 2>/dev/null || true
    helm uninstall prometheus -n monitoring 2>/dev/null || true
    helm uninstall loki -n monitoring 2>/dev/null || true
    helm uninstall tempo -n monitoring 2>/dev/null || true
    helm uninstall promtail -n monitoring 2>/dev/null || true
    helm uninstall vault -n vault 2>/dev/null || true
    helm uninstall keycloak -n keycloak 2>/dev/null || true
    helm uninstall external-secrets -n external-secrets 2>/dev/null || true
    helm uninstall cert-manager -n cert-manager 2>/dev/null || true
    
    kubectl delete -k "${OVERLAY_DIR}/devops" 2>/dev/null || true
    
    log_info "DevOps platform deleted"
}

status_devops() {
    log_step "DevOps Platform Status:"
    echo ""
    for ns in keycloak vault gitlab argocd monitoring external-secrets cert-manager; do
        echo "=== ${ns} ==="
        kubectl get pods -n "$ns" 2>/dev/null || echo "  Namespace not found"
        echo ""
    done
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    echo ""
    echo "=============================================="
    echo "Deployment Complete!"
    echo "Environment: ${ENV}"
    echo "Domain: ${DOMAIN}"
    echo "=============================================="
    echo ""
    echo "Applications:"
    echo "  - https://app.${DOMAIN}"
    echo "  - https://api.${DOMAIN}"
    echo "  - https://hello.${DOMAIN}"
    echo ""
    echo "DevOps Platform:"
    echo "  - Keycloak:   https://keycloak.${DOMAIN}"
    echo "  - Vault:      https://vault.${DOMAIN}"
    echo "  - Grafana:    https://grafana.${DOMAIN}"
    echo "  - Prometheus: https://prometheus.${DOMAIN}"
    echo "  - GitLab:     https://gitlab.${DOMAIN}"
    echo "  - ArgoCD:     https://argocd.${DOMAIN}"
    echo ""
    echo "Credentials:"
    echo "  Keycloak:  kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.admin-password}' | base64 -d"
    echo "  Grafana:   kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d"
    echo "  ArgoCD:    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo "  GitLab:    kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    if [[ "$ENV" == "local" ]]; then
        echo "For Windows access, run (as Admin):"
        echo "  cd k8s/scripts/windows && .\\setup-all.ps1"
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "=============================================="
    echo "Kubernetes Deploy: ${ENV} / ${COMPONENT} / ${ACTION}"
    echo "=============================================="
    
    check_requirements
    
    case "$ACTION" in
        deploy)
            case "$COMPONENT" in
                all)
                    [[ "$ENV" == "local" ]] && copy_tls_secrets
                    deploy_apps
                    deploy_devops
                    print_summary
                    ;;
                apps)
                    [[ "$ENV" == "local" ]] && copy_tls_secrets
                    deploy_apps
                    ;;
                devops)
                    deploy_devops
                    print_summary
                    ;;
                keycloak)
                    add_helm_repos && install_keycloak
                    ;;
                vault)
                    add_helm_repos && install_vault
                    ;;
                monitoring)
                    add_helm_repos && install_monitoring
                    ;;
                gitlab)
                    add_helm_repos && install_gitlab
                    ;;
                argocd)
                    add_helm_repos && install_argocd
                    ;;
                ingress)
                    kubectl apply -k "${OVERLAY_DIR}/apps"
                    kubectl apply -k "${OVERLAY_DIR}/devops"
                    ;;
                *)
                    log_error "Unknown component: $COMPONENT"
                    exit 1
                    ;;
            esac
            ;;
        status)
            case "$COMPONENT" in
                all|apps) status_apps ;;
            esac
            case "$COMPONENT" in
                all|devops) status_devops ;;
            esac
            ;;
        delete)
            case "$COMPONENT" in
                all)
                    delete_apps
                    delete_devops
                    ;;
                apps)
                    delete_apps
                    ;;
                devops)
                    delete_devops
                    ;;
                *)
                    log_error "Unknown component: $COMPONENT"
                    exit 1
                    ;;
            esac
            ;;
        *)
            log_error "Unknown action: $ACTION"
            exit 1
            ;;
    esac
}

main
