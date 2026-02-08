#!/bin/bash
set -euo pipefail

# =============================================================================
# UpCloud Kubernetes Cluster Setup Script
# =============================================================================
# This script configures an UpCloud managed Kubernetes cluster with
# nginx-ingress and cert-manager for automatic TLS certificates.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../.."

# Configuration
CERT_MANAGER_VERSION="v1.14.4"
NGINX_INGRESS_VERSION="4.9.1"

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
        exit 1
    fi
    
    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        log_error "Make sure you have configured kubectl to connect to your UpCloud cluster."
        log_info "Download kubeconfig from UpCloud control panel."
        exit 1
    fi
    
    # Verify we're connected to UpCloud (not local)
    local context=$(kubectl config current-context)
    log_info "Connected to cluster: ${context}"
    
    read -p "Is this the correct UpCloud cluster? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Aborted. Please configure kubectl for the correct cluster."
        exit 1
    fi
    
    log_info "All requirements satisfied."
}

# Install cert-manager
install_cert_manager() {
    log_step "Installing cert-manager..."
    
    # Add helm repo
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update jetstack
    
    # Check if already installed
    if helm list -n cert-manager | grep -q cert-manager; then
        log_warn "cert-manager already installed. Upgrading..."
    fi
    
    # Install cert-manager with CRDs
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version "${CERT_MANAGER_VERSION}" \
        --set installCRDs=true \
        --set prometheus.enabled=false \
        --wait \
        --timeout 5m
    
    log_info "cert-manager installed successfully."
    
    # Wait for cert-manager to be ready
    log_info "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=ready pod \
        --all \
        --namespace cert-manager \
        --timeout=120s
}

# Install nginx-ingress controller
install_nginx_ingress() {
    log_step "Installing nginx-ingress controller..."
    
    # Check if UpCloud has a built-in ingress controller
    local existing_ingress=$(kubectl get pods -n ingress-nginx 2>/dev/null | grep -c ingress-nginx || echo "0")
    
    if [[ "${existing_ingress}" -gt 0 ]]; then
        log_warn "nginx-ingress appears to be already installed."
        read -p "Do you want to reinstall/upgrade it? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping nginx-ingress installation."
            return 0
        fi
    fi
    
    # Add helm repo
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx
    
    # Install/upgrade nginx-ingress with UpCloud-specific settings
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --version "${NGINX_INGRESS_VERSION}" \
        --set controller.service.type=LoadBalancer \
        --set controller.config.proxy-body-size="100m" \
        --set controller.config.ssl-redirect="true" \
        --set controller.config.use-forwarded-headers="true" \
        --set controller.config.compute-full-forwarded-for="true" \
        --set controller.resources.requests.cpu="100m" \
        --set controller.resources.requests.memory="128Mi" \
        --set controller.resources.limits.cpu="500m" \
        --set controller.resources.limits.memory="512Mi" \
        --wait \
        --timeout 5m
    
    log_info "nginx-ingress controller installed successfully."
}

# Wait for LoadBalancer IP
wait_for_loadbalancer() {
    log_step "Waiting for LoadBalancer external IP..."
    
    local EXTERNAL_IP=""
    local attempts=0
    local max_attempts=60
    
    while [[ -z "${EXTERNAL_IP}" && ${attempts} -lt ${max_attempts} ]]; do
        EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [[ -z "${EXTERNAL_IP}" ]]; then
            EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        fi
        
        if [[ -z "${EXTERNAL_IP}" ]]; then
            ((attempts++))
            echo -n "."
            sleep 5
        fi
    done
    echo ""
    
    if [[ -z "${EXTERNAL_IP}" ]]; then
        log_error "Could not get external IP after ${max_attempts} attempts."
        log_warn "The LoadBalancer may still be provisioning. Check later with:"
        log_warn "kubectl get svc -n ingress-nginx"
    else
        log_info "LoadBalancer external IP: ${EXTERNAL_IP}"
        echo ""
        echo "=============================================="
        echo "IMPORTANT: Update your DNS records!"
        echo "=============================================="
        echo "Point your domains to: ${EXTERNAL_IP}"
        echo ""
        echo "Example DNS records:"
        echo "  app.yourdomain.com  A  ${EXTERNAL_IP}"
        echo "  api.yourdomain.com  A  ${EXTERNAL_IP}"
        echo "=============================================="
    fi
}

# Create namespace
create_namespace() {
    log_step "Creating namespace..."
    
    kubectl apply -f "${K8S_DIR}/base/namespace.yaml"
    
    log_info "Namespace created."
}

# Apply cluster issuers
apply_cluster_issuers() {
    log_step "Applying cert-manager ClusterIssuers..."
    
    # Check if email is configured
    if grep -q "your-email@example.com" "${K8S_DIR}/overlays/upcloud/cert-manager/cluster-issuer.yaml"; then
        log_error "Please update the email address in cert-manager/cluster-issuer.yaml"
        log_error "Let's Encrypt requires a valid email for certificate notifications."
        exit 1
    fi
    
    kubectl apply -f "${K8S_DIR}/overlays/upcloud/cert-manager/cluster-issuer.yaml"
    
    log_info "ClusterIssuers applied."
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    echo "UpCloud Cluster Setup Complete!"
    echo "=============================================="
    echo ""
    echo "Installed components:"
    echo "  - cert-manager ${CERT_MANAGER_VERSION}"
    echo "  - nginx-ingress ${NGINX_INGRESS_VERSION}"
    echo ""
    echo "Next steps:"
    echo "1. Update DNS records to point to the LoadBalancer IP"
    echo "2. Update domain names in overlays/upcloud/ingress.yaml"
    echo "3. Update email in overlays/upcloud/cert-manager/cluster-issuer.yaml"
    echo "4. Deploy your services: ./deploy.sh"
    echo ""
}

# Main execution
main() {
    echo "=============================================="
    echo "UpCloud Kubernetes Cluster Setup"
    echo "=============================================="
    
    check_requirements
    install_cert_manager
    install_nginx_ingress
    wait_for_loadbalancer
    create_namespace
    apply_cluster_issuers
    print_summary
}

main "$@"
