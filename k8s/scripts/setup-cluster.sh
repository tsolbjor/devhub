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
#
# `helm uninstall` alone is not enough: k3s installs Traefik through a packaged
# manifest that creates HelmChart CRs, and its helm-controller reconciles those
# back into a release. Removing the release while the CR remains means Traefik
# returns within seconds, so the CRs go first. The packaged manifest itself lives
# inside the VM and is re-applied on every k3s start, which is why this has to be
# re-runnable and why the durable fix is the Rancher Desktop setting.
remove_traefik() {
    [[ "$ENV" == "local" ]] || return 0

    local present=0
    kubectl get helmchart traefik -n kube-system &>/dev/null && present=1
    helm list -n kube-system 2>/dev/null | grep -q traefik && present=1
    kubectl get svc traefik -n kube-system &>/dev/null && present=1

    if [[ $present -eq 0 ]]; then
        log_info "Traefik not present"
        return 0
    fi

    log_step "Removing Traefik to free ports 80/443..."

    # CRs first — otherwise helm-controller reinstates the release we just removed.
    kubectl delete helmchart traefik traefik-crd -n kube-system \
        --ignore-not-found --wait=false 2>/dev/null || true
    helm uninstall traefik -n kube-system 2>/dev/null || true
    helm uninstall traefik-crd -n kube-system 2>/dev/null || true
    # The Service owns the klipper-lb DaemonSet that actually holds the host ports.
    kubectl delete svc traefik -n kube-system --ignore-not-found 2>/dev/null || true

    # Envoy's own klipper-lb pod stays Pending until the host ports are free, so
    # wait for the port holder to go rather than racing deploy.sh with a sleep.
    local waited=0
    while kubectl get pods -n kube-system -l svccontroller.k3s.cattle.io/svcname=traefik \
              -o name 2>/dev/null | grep -q .; do
        [[ $waited -ge 60 ]] && { log_warn "svclb-traefik still running after 60s"; break; }
        sleep 3
        waited=$((waited + 3))
    done

    log_info "Traefik removed"
    log_warn "k3s re-adds Traefik on every Rancher Desktop restart, which leaves the"
    log_warn "Gateway without an address. Turn it off for good in Rancher Desktop:"
    log_warn "  Preferences → Kubernetes → uncheck 'Enable Traefik'"
    log_warn "Until then, re-run: ./devhub cluster --env ${ENV}"
}

# Envoy's LoadBalancer Service is what gives the Gateway its address. On a
# single-node k3s that means a klipper-lb pod binding host ports 80/443, so
# anything else already holding them leaves the Gateway stuck at
# "AddressNotAssigned" with no clue as to why.
check_host_ports() {
    [[ "$ENV" == "local" ]] || return 0

    local holders
    holders="$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {range .spec.containers[*]}{range .ports[*]}{.hostPort}{" "}{end}{end}{"\n"}{end}' 2>/dev/null \
        | awk '$0 ~ /(^| )(80|443)( |$)/ {print $1}' \
        | grep -v '^kube-system/svclb-envoy-gateway' || true)"

    if [[ -n "$holders" ]]; then
        log_warn "Host ports 80/443 are held by:"
        echo "$holders" | sed 's/^/  /'
        log_warn "Envoy Gateway cannot bind them; the Gateway will report AddressNotAssigned."
    else
        log_info "Host ports 80/443 are free for Envoy Gateway"
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
    check_host_ports
    label_local_ci_node
    check_storage_class

    echo ""
    log_info "Cluster ready. Next: ./devhub deploy --env ${ENV}"
    echo ""
}

main
