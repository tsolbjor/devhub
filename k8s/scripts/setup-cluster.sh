#!/bin/bash
set -euo pipefail

# =============================================================================
# Cluster Preparation
# =============================================================================
# The few things that must happen to a cluster before deploy.sh runs, and which
# deploy.sh cannot do for itself.
#
# Everything this script used to do — installing an ingress controller,
# cert-manager, namespaces and TLS secrets — now lives in deploy.sh, which owns
# the whole component graph. Keeping a second copy here meant two places to fix
# whenever a component changed.
#
# Usage: ./setup-cluster.sh --env <environment>
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
setup_paths
parse_config
use_env_kubeconfig

check_cluster_requirements() {
    log_step "Checking cluster access..."

    command -v kubectl &>/dev/null || { log_error "kubectl is required"; exit 1; }
    command -v helm &>/dev/null || { log_error "helm is required"; exit 1; }

    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to the Kubernetes cluster."
        if [[ "$ENV" == "local" ]]; then
            log_error "Start Rancher Desktop (or your local Kubernetes) and try again."
        else
            log_error "Fetch credentials first: ./devhub sync --env ${ENV}"
        fi
        exit 1
    fi

    log_info "Connected to: $(kubectl config current-context)"
}

# Rancher Desktop ships Traefik on ports 80/443. Envoy Gateway needs them.
remove_traefik() {
    [[ "$ENV" == "local" ]] || return 0

    if helm list -n kube-system 2>/dev/null | grep -q traefik; then
        log_step "Removing Traefik to free ports 80/443..."
        helm uninstall traefik -n kube-system 2>/dev/null || true
        helm uninstall traefik-crd -n kube-system 2>/dev/null || true
        sleep 5
        log_info "Traefik removed"
    else
        log_info "Traefik not present"
    fi
}

# On the clouds the CI pool carries role=ci and the workload=ci taint, and Kyverno
# pins pipeline pods to it. Locally there is one node and no pool, so it gets the
# label — otherwise every CI pod sits Pending on a nodeSelector nothing satisfies.
label_local_ci_node() {
    [[ "$ENV" == "local" ]] || return 0

    log_step "Labelling the local node as a CI node..."
    kubectl label nodes --all role=ci --overwrite >/dev/null
    log_info "role=ci applied (single-node cluster runs CI alongside the platform)"
}

check_certificates() {
    [[ "$ENV" == "local" ]] || return 0

    if [[ ! -f "${CERTS_DIR}/domains/local-dev.crt" ]]; then
        log_error "Local certificates are missing."
        log_error "Run: ./devhub ca --env local"
        exit 1
    fi
    log_info "Local CA certificates present"
}

check_storage_class() {
    local default_sc
    default_sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)"

    if [[ -n "$default_sc" ]]; then
        log_info "Default StorageClass: ${default_sc}"
    elif [[ "$(env_cloud)" == "aws" ]]; then
        log_info "No default StorageClass yet — deploy.sh installs gp3 for EKS"
    else
        log_warn "No default StorageClass. Vault, Forgejo, Prometheus and Loki all need one."
    fi
}

main() {
    log_phase "Preparing cluster for ${ENV}"

    check_cluster_requirements
    check_certificates
    remove_traefik
    label_local_ci_node
    check_storage_class

    echo ""
    log_info "Cluster ready. Next: ./devhub deploy --env ${ENV}"
    echo ""
}

main
