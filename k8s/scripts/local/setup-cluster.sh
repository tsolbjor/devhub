#!/bin/bash
set -euo pipefail

# =============================================================================
# Local Kubernetes Cluster Setup Script
# =============================================================================
# This script configures a local Kubernetes cluster (Rancher Desktop)
# with nginx-ingress and required resources for local development.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../.."
CERTS_DIR="${K8S_DIR}/certs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check requirements
check_requirements() {
    log_info "Checking requirements..."
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is required but not installed."
        exit 1
    fi
    
    if ! command -v helm &> /dev/null; then
        log_error "helm is required but not installed."
        log_info "Install with: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
        exit 1
    fi
    
    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        log_error "Make sure Rancher Desktop is running and Kubernetes is enabled."
        exit 1
    fi
    
    log_info "All requirements satisfied."
}

# Check if certificates exist
check_certificates() {
    log_info "Checking for certificates..."
    
    if [[ ! -f "${CERTS_DIR}/ca/ca.crt" ]]; then
        log_error "CA certificate not found. Run setup-ca.sh first."
        exit 1
    fi
    
    if [[ ! -f "${CERTS_DIR}/domains/local-dev.crt" ]]; then
        log_error "Domain certificate not found. Run setup-ca.sh first."
        exit 1
    fi
    
    log_info "Certificates found."
}

# Install nginx-ingress controller
install_nginx_ingress() {
    log_step "Installing nginx-ingress controller..."
    
    # Add helm repo
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx
    
    # Check if already installed
    if helm list -n ingress-nginx | grep -q ingress-nginx; then
        log_warn "nginx-ingress already installed. Upgrading..."
    fi
    
    # Install/upgrade with custom values for local development
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.service.type=LoadBalancer \
        --set controller.service.externalTrafficPolicy=Local \
        --set controller.config.proxy-body-size="100m" \
        --set controller.config.ssl-redirect="true" \
        --set controller.config.use-forwarded-headers="true" \
        --set controller.config.compute-full-forwarded-for="true" \
        --set controller.config.use-proxy-protocol="false" \
        --set controller.extraArgs.default-ssl-certificate="tshub/local-tls-secret" \
        --wait \
        --timeout 5m
    
    log_info "nginx-ingress controller installed successfully."
}

# Wait for ingress controller to be ready
wait_for_ingress() {
    log_step "Waiting for ingress controller to be ready..."
    
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=120s
    
    # Get the external IP/port
    local EXTERNAL_IP=""
    local attempts=0
    local max_attempts=30
    
    while [[ -z "${EXTERNAL_IP}" && ${attempts} -lt ${max_attempts} ]]; do
        EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [[ -z "${EXTERNAL_IP}" ]]; then
            EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        fi
        
        if [[ -z "${EXTERNAL_IP}" ]]; then
            ((attempts++))
            sleep 2
        fi
    done
    
    if [[ -z "${EXTERNAL_IP}" ]]; then
        log_warn "Could not get external IP. Using NodePort instead."
        EXTERNAL_IP="localhost"
    fi
    
    log_info "Ingress controller ready at: ${EXTERNAL_IP}"
}

# Create namespace
create_namespace() {
    log_step "Creating namespace..."
    
    kubectl apply -f "${K8S_DIR}/base/namespace.yaml"
    
    log_info "Namespace created."
}

# Apply TLS secret and CA ConfigMap
apply_secrets() {
    log_step "Applying TLS secrets and CA certificates..."
    
    # Create namespace first if it doesn't exist
    kubectl create namespace tshub 2>/dev/null || true
    
    # Apply TLS secret
    if [[ -f "${K8S_DIR}/overlays/local/tls-secret.yaml" ]]; then
        kubectl apply -f "${K8S_DIR}/overlays/local/tls-secret.yaml"
        log_info "TLS secret applied."
    else
        log_warn "TLS secret not found. Run setup-ca.sh first."
    fi
    
    # Apply CA ConfigMap
    if [[ -f "${K8S_DIR}/overlays/local/ca-configmap.yaml" ]]; then
        kubectl apply -f "${K8S_DIR}/overlays/local/ca-configmap.yaml"
        log_info "CA ConfigMap applied."
    else
        log_warn "CA ConfigMap not found. Run setup-ca.sh first."
    fi
}

# Configure CoreDNS for local domains (optional)
configure_coredns() {
    log_step "Configuring CoreDNS for local domains..."
    
    # Get current CoreDNS ConfigMap
    local COREDNS_CM=$(kubectl get configmap coredns -n kube-system -o yaml 2>/dev/null || echo "")
    
    if [[ -z "${COREDNS_CM}" ]]; then
        log_warn "CoreDNS ConfigMap not found. Skipping CoreDNS configuration."
        return 0
    fi
    
    # Check if local.dev is already configured
    if echo "${COREDNS_CM}" | grep -q "local.dev"; then
        log_info "CoreDNS already configured for local.dev"
        return 0
    fi
    
    log_info "CoreDNS configuration complete."
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    echo "Local Cluster Setup Complete!"
    echo "=============================================="
    echo ""
    echo "Ingress Controller: nginx-ingress"
    echo "Namespace: tshub"
    echo ""
    echo "Next steps:"
    echo "1. Make sure Windows hosts file is configured:"
    echo "   powershell -ExecutionPolicy Bypass -File scripts/windows/setup-hosts.ps1"
    echo ""
    echo "2. Deploy your services:"
    echo "   ./deploy.sh"
    echo ""
    echo "3. Access services at:"
    echo "   - https://app.local.dev"
    echo "   - https://api.local.dev"
    echo ""
}

# Main execution
main() {
    echo "=============================================="
    echo "Local Kubernetes Cluster Setup"
    echo "=============================================="
    
    check_requirements
    check_certificates
    install_nginx_ingress
    create_namespace
    apply_secrets
    wait_for_ingress
    configure_coredns
    print_summary
}

main "$@"
