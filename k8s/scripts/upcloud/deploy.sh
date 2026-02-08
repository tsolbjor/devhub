#!/bin/bash
set -euo pipefail

# =============================================================================
# UpCloud Deployment Script
# =============================================================================
# This script deploys services to the UpCloud Kubernetes cluster using Kustomize.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../.."
OVERLAY_DIR="${K8S_DIR}/overlays/upcloud"

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
    
    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        exit 1
    fi
    
    # Verify cluster context
    local context=$(kubectl config current-context)
    log_info "Deploying to cluster: ${context}"
    
    read -p "Continue with deployment? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Aborted."
        exit 1
    fi
    
    log_info "All requirements satisfied."
}

# Pre-flight checks
preflight_checks() {
    log_step "Running pre-flight checks..."
    
    # Check if ingress domains are configured
    if grep -q "yourdomain.com" "${OVERLAY_DIR}/ingress.yaml"; then
        log_error "Please update the domain names in overlays/upcloud/ingress.yaml"
        exit 1
    fi
    
    # Check if cert-manager is running
    if ! kubectl get pods -n cert-manager 2>/dev/null | grep -q Running; then
        log_error "cert-manager is not running. Run setup-cluster.sh first."
        exit 1
    fi
    
    # Check if nginx-ingress is running
    if ! kubectl get pods -n ingress-nginx 2>/dev/null | grep -q Running; then
        log_error "nginx-ingress is not running. Run setup-cluster.sh first."
        exit 1
    fi
    
    log_info "Pre-flight checks passed."
}

# Deploy using Kustomize
deploy() {
    log_step "Deploying to UpCloud cluster..."
    
    # Check if overlay exists
    if [[ ! -d "${OVERLAY_DIR}" ]]; then
        log_error "UpCloud overlay not found at ${OVERLAY_DIR}"
        exit 1
    fi
    
    # Apply base manifests first
    log_info "Applying base manifests..."
    kubectl apply -f "${K8S_DIR}/base/"
    
    # Apply upcloud overlay
    log_info "Applying UpCloud overlay..."
    kubectl apply -k "${OVERLAY_DIR}"
    
    log_info "Deployment complete."
}

# Wait for pods to be ready
wait_for_pods() {
    log_step "Waiting for pods to be ready..."
    
    kubectl wait --for=condition=ready pod \
        --all \
        --namespace tshub \
        --timeout=300s 2>/dev/null || log_warn "Some pods may not be ready yet."
    
    log_info "Pods are ready."
}

# Wait for certificate to be issued
wait_for_certificate() {
    log_step "Waiting for TLS certificate to be issued..."
    
    local attempts=0
    local max_attempts=60
    
    while [[ ${attempts} -lt ${max_attempts} ]]; do
        local cert_status=$(kubectl get certificate -n tshub -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        
        if [[ "${cert_status}" == "True" ]]; then
            log_info "TLS certificate issued successfully!"
            return 0
        fi
        
        ((attempts++))
        echo -n "."
        sleep 5
    done
    echo ""
    
    log_warn "Certificate may still be issuing. Check status with:"
    log_warn "kubectl get certificate -n tshub"
    log_warn "kubectl describe certificate -n tshub"
}

# Show deployment status
show_status() {
    log_step "Deployment Status:"
    echo ""
    
    echo "Pods:"
    kubectl get pods -n tshub -o wide 2>/dev/null || echo "  No pods found"
    echo ""
    
    echo "Services:"
    kubectl get svc -n tshub 2>/dev/null || echo "  No services found"
    echo ""
    
    echo "Ingress:"
    kubectl get ingress -n tshub 2>/dev/null || echo "  No ingress found"
    echo ""
    
    echo "Certificates:"
    kubectl get certificate -n tshub 2>/dev/null || echo "  No certificates found"
    echo ""
}

# Print access information
print_access_info() {
    echo ""
    echo "=============================================="
    echo "Deployment Complete!"
    echo "=============================================="
    echo ""
    echo "Your services should be available at the domains"
    echo "configured in your ingress."
    echo ""
    echo "Useful commands:"
    echo "  kubectl get pods -n tshub"
    echo "  kubectl logs -n tshub <pod-name>"
    echo "  kubectl describe certificate -n tshub"
    echo "  kubectl get events -n tshub --sort-by='.lastTimestamp'"
    echo ""
}

# Main execution
main() {
    local action="${1:-deploy}"
    
    case "${action}" in
        deploy)
            echo "=============================================="
            echo "UpCloud Deployment"
            echo "=============================================="
            check_requirements
            preflight_checks
            deploy
            wait_for_pods
            wait_for_certificate
            show_status
            print_access_info
            ;;
        status)
            show_status
            ;;
        delete)
            log_step "Deleting deployment..."
            kubectl delete -k "${OVERLAY_DIR}" 2>/dev/null || true
            log_info "Deployment deleted."
            ;;
        *)
            echo "Usage: $0 [deploy|status|delete]"
            exit 1
            ;;
    esac
}

main "$@"
