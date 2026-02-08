#!/bin/bash
set -euo pipefail

# =============================================================================
# Local Deployment Script
# =============================================================================
# This script deploys services to the local Kubernetes cluster using Kustomize.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../.."
OVERLAY_DIR="${K8S_DIR}/overlays/local"

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
    
    log_info "All requirements satisfied."
}

# Deploy using Kustomize
deploy() {
    log_step "Deploying to local cluster..."
    
    # Check if overlay exists
    if [[ ! -d "${OVERLAY_DIR}" ]]; then
        log_error "Local overlay not found at ${OVERLAY_DIR}"
        exit 1
    fi
    
    # Apply base manifests first
    log_info "Applying base manifests..."
    kubectl apply -f "${K8S_DIR}/base/"
    
    # Apply local overlay
    log_info "Applying local overlay..."
    kubectl apply -k "${OVERLAY_DIR}"
    
    log_info "Deployment complete."
}

# Wait for pods to be ready
wait_for_pods() {
    log_step "Waiting for pods to be ready..."
    
    # Wait for all pods in namespace to be ready
    kubectl wait --for=condition=ready pod \
        --all \
        --namespace tshub \
        --timeout=300s 2>/dev/null || log_warn "Some pods may not be ready yet."
    
    log_info "Pods are ready."
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
}

# Print access information
print_access_info() {
    echo ""
    echo "=============================================="
    echo "Deployment Complete!"
    echo "=============================================="
    echo ""
    echo "Access your services at:"
    echo "  - https://app.local.dev"
    echo "  - https://api.local.dev"
    echo ""
    echo "Useful commands:"
    echo "  kubectl get pods -n tshub"
    echo "  kubectl logs -n tshub <pod-name>"
    echo "  kubectl describe ingress -n tshub"
    echo ""
}

# Main execution
main() {
    local action="${1:-deploy}"
    
    case "${action}" in
        deploy)
            echo "=============================================="
            echo "Local Deployment"
            echo "=============================================="
            check_requirements
            deploy
            wait_for_pods
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
