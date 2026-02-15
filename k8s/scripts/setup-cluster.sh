#!/bin/bash
set -euo pipefail

# =============================================================================
# Kubernetes Cluster Setup Script
# =============================================================================
# Configures a Kubernetes cluster with nginx-ingress and required resources.
# Local: Uses local CA certs + removes Traefik
# UpCloud: Uses cert-manager + cloud LoadBalancer
#
# Usage: ./setup-cluster.sh --env local|upcloud
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
setup_paths
parse_config

# =============================================================================
# Shared Functions
# =============================================================================

check_cluster_requirements() {
    log_info "Checking requirements..."

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl is required but not installed."
        exit 1
    fi

    if ! command -v helm &>/dev/null; then
        log_error "helm is required but not installed."
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        if [[ "$ENV" == "local" ]]; then
            log_error "Make sure Rancher Desktop is running and Kubernetes is enabled."
        else
            log_error "Make sure you have configured kubectl to connect to your UpCloud cluster."
            log_info "Download kubeconfig from UpCloud control panel."
        fi
        exit 1
    fi

    log_info "All requirements satisfied."
}

install_nginx_ingress_local() {
    log_step "Installing nginx-ingress controller (local)..."

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx

    if helm list -n ingress-nginx | grep -q ingress-nginx; then
        log_warn "nginx-ingress already installed. Upgrading..."
    fi

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
        --set controller.admissionWebhooks.enabled=false \
        --timeout 5m

    log_info "nginx-ingress controller installed successfully."
}

install_nginx_ingress_upcloud() {
    log_step "Installing nginx-ingress controller (UpCloud)..."

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx

    if helm list -n ingress-nginx | grep -q ingress-nginx; then
        log_warn "nginx-ingress already installed. Upgrading..."
    fi

    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
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

wait_for_ingress() {
    log_step "Waiting for ingress controller to be ready..."

    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=120s

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

    if [[ "$ENV" == "upcloud" && "${EXTERNAL_IP}" != "localhost" ]]; then
        echo ""
        echo "=============================================="
        echo "IMPORTANT: Update your DNS records!"
        echo "=============================================="
        echo "Point your domains to: ${EXTERNAL_IP}"
        echo ""
    fi
}

# =============================================================================
# Local-specific Functions
# =============================================================================

check_certificates() {
    log_info "Checking for certificates..."

    if [[ ! -f "${CERTS_DIR}/ca/ca.crt" ]]; then
        log_error "CA certificate not found. Run setup-ca.sh --env local first."
        exit 1
    fi

    if [[ ! -f "${CERTS_DIR}/domains/local-dev.crt" ]]; then
        log_error "Domain certificate not found. Run setup-ca.sh --env local first."
        exit 1
    fi

    log_info "Certificates found."
}

remove_traefik() {
    if helm list -n kube-system 2>/dev/null | grep -q traefik; then
        log_step "Removing Traefik (Rancher Desktop default) to free ports 80/443 for nginx-ingress..."
        helm uninstall traefik -n kube-system 2>/dev/null || true
        helm uninstall traefik-crd -n kube-system 2>/dev/null || true
        sleep 5
        log_info "Traefik removed"
    fi
}

create_namespace() {
    log_step "Creating namespace..."
    kubectl create namespace tshub 2>/dev/null || true
    log_info "Namespace created."
}

apply_secrets() {
    log_step "Applying TLS secrets and CA certificates..."

    kubectl create namespace tshub 2>/dev/null || true

    if [[ -f "${OVERLAY_DIR}/tls-secret.yaml" ]]; then
        kubectl apply -f "${OVERLAY_DIR}/tls-secret.yaml"
        log_info "TLS secret applied."
    else
        log_warn "TLS secret not found. Run setup-ca.sh --env local first."
    fi

    if [[ -f "${OVERLAY_DIR}/ca-configmap.yaml" ]]; then
        kubectl apply -f "${OVERLAY_DIR}/ca-configmap.yaml"
        log_info "CA ConfigMap applied."
    else
        log_warn "CA ConfigMap not found. Run setup-ca.sh --env local first."
    fi
}

# =============================================================================
# UpCloud-specific Functions
# =============================================================================

install_cert_manager_upcloud() {
    log_step "Installing cert-manager..."

    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update jetstack

    if helm list -n cert-manager | grep -q cert-manager; then
        log_warn "cert-manager already installed. Upgrading..."
    fi

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set installCRDs=true \
        --set prometheus.enabled=false \
        --wait \
        --timeout 5m

    log_info "cert-manager installed successfully."

    log_info "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=ready pod \
        --all \
        --namespace cert-manager \
        --timeout=120s
}

apply_cluster_issuers() {
    log_step "Applying cert-manager ClusterIssuers..."

    local issuer_file="${OVERLAY_DIR}/cert-manager/cluster-issuer.yaml"
    if [[ -f "$issuer_file" ]]; then
        if grep -q "your-email@example.com" "$issuer_file"; then
            log_error "Please update the email address in cert-manager/cluster-issuer.yaml"
            exit 1
        fi
        kubectl apply -f "$issuer_file"
        log_info "ClusterIssuers applied."
    else
        log_warn "ClusterIssuer file not found: $issuer_file"
    fi
}

# =============================================================================
# Main
# =============================================================================

print_summary() {
    echo ""
    echo "=============================================="
    echo "Cluster Setup Complete! (env: ${ENV})"
    echo "=============================================="
    echo ""
    echo "Ingress Controller: nginx-ingress"
    echo ""
    echo "Next steps:"
    if [[ "$ENV" == "local" ]]; then
        echo "1. Make sure Windows hosts file is configured:"
        echo "   powershell -ExecutionPolicy Bypass -File scripts/windows/setup-hosts.ps1"
        echo ""
        echo "2. Deploy your services:"
        echo "   ./deploy.sh --env local"
    else
        echo "1. Update DNS records to point to the LoadBalancer IP"
        echo "2. Deploy your services:"
        echo "   ./deploy.sh --env upcloud"
    fi
    echo ""
}

main() {
    echo "=============================================="
    echo "Kubernetes Cluster Setup (${ENV})"
    echo "=============================================="

    check_cluster_requirements

    case "$ENV" in
        local)
            check_certificates
            create_namespace
            apply_secrets
            remove_traefik
            install_nginx_ingress_local
            wait_for_ingress
            ;;
        upcloud)
            install_cert_manager_upcloud
            install_nginx_ingress_upcloud
            wait_for_ingress
            create_namespace
            apply_cluster_issuers
            ;;
    esac

    print_summary
}

main
