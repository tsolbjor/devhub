#!/bin/bash
set -euo pipefail

# =============================================================================
# Workload Cluster Deploy Script
# =============================================================================
# Installs the minimal platform components on a workload cluster:
#   - Envoy Gateway        Gateway API implementation + wildcard-TLS Gateway
#   - cert-manager         TLS certificates (DNS-01 issuer for the wildcard)
#   - external-dns         DNS records from HTTPRoutes
#   - external-secrets     pulls app secrets from the platform Vault
#   - alloy                forwards logs to the platform Loki
#   - Kyverno              enforces app guardrails and generates namespace defaults
#
# Keycloak, Vault, Forgejo, ArgoCD and the monitoring backends live on the
# platform cluster; ArgoCD there deploys apps here.
#
# Usage:
#   ./deploy-workload.sh --env aws-workload|azure-workload|gcp-workload|upcloud-workload [component]
#
# Components: all (default), gateway, cert-manager, external-dns,
#             external-secrets, alloy, kyverno, storage, policies
#
# Prerequisites:
#   - ./sync-tofu-outputs.sh --env <workload-env>   (writes kubeconfig + outputs)
#   - platformVaultUrl / platformLokiUrl set in the overlay config.yaml
#   - ./register-workload-cluster.sh --env <workload-env> for Vault + ArgoCD wiring
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
# Empty-array expansion is unsafe under `set -u` on older bash.
if [[ ${#ARGS[@]} -gt 0 ]]; then set -- "${ARGS[@]}"; else set --; fi

COMPONENT="${1:-all}"

if ! is_workload_env; then
    log_error "deploy-workload.sh is for workload environments only"
    log_error "Valid: ${WORKLOAD_ENVS}"
    log_error "For platform clusters, use: ./deploy.sh --env ${ENV}"
    exit 1
fi

CLOUD="$(env_cloud)"

setup_paths
parse_config

# Target the workload cluster explicitly. Previously this script used whatever
# context happened to be active, so running it with the platform kubeconfig
# loaded reinstalled ingress-nginx and cert-manager over the platform cluster.
use_env_kubeconfig

CONFIG_FILE="${OVERLAY_DIR}/config.yaml"

# Mirrors the pins in deploy.sh.
CHART_CERT_MANAGER="v1.21.1"
CHART_EXTERNAL_DNS="1.21.1"
CHART_EXTERNAL_SECRETS="2.9.0"
CHART_ALLOY="1.11.1"
CHART_ENVOY_GATEWAY="1.9.0"
CHART_KYVERNO="3.8.2"

# =============================================================================
# Component Install Functions
# =============================================================================

install_storage_class() {
    if [[ "$CLOUD" != "aws" ]]; then return 0; fi

    log_step "Applying gp3 default StorageClass..."
    kubectl apply -f "${BASE_DIR}/devops/storage/storageclass-aws.yaml"
    if kubectl get storageclass gp2 &>/dev/null; then
        kubectl patch storageclass gp2 \
            -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
            &>/dev/null || true
    fi
    log_info "gp3 is the default StorageClass"
}

install_scheduling_policies() {
    log_step "Applying priority classes..."
    kubectl apply -f "${BASE_DIR}/devops/policy/priority-classes.yaml"
    log_info "Priority classes applied"
}

install_cert_manager() {
    log_step "Installing cert-manager..."

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version "$CHART_CERT_MANAGER" \
        --set crds.enabled=true \
        --set global.priorityClassName=platform-standard \
        --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
        --set config.kind=ControllerConfiguration \
        --set config.enableGatewayAPI=true \
        --atomic --timeout 5m

    log_step "Creating Let's Encrypt ClusterIssuers..."

    # HTTP-01 for individual hostnames, solved through the Gateway.
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: devhub
                namespace: gateway
                kind: Gateway
EOF

    # DNS-01 for the wildcard certificate the apps listener serves. Let's Encrypt
    # will not issue a wildcard over HTTP-01, so this is not optional.
    create_dns01_issuer

    log_info "cert-manager installed"
}

# The DNS-01 solver differs per cloud; the credentials are the same workload
# identity external-dns already uses.
create_dns01_issuer() {
    local solver=""
    case "$CLOUD" in
        aws)
            solver="      - dns01:
          route53:
            region: ${AWS_REGION:-eu-west-1}"
            ;;
        azure)
            solver="      - dns01:
          azureDNS:
            resourceGroupName: ${AZURE_RESOURCE_GROUP:-}
            subscriptionID: ${AZURE_SUBSCRIPTION_ID:-}
            hostedZoneName: ${DOMAIN}
            environment: AzurePublicCloud
            managedIdentity:
              clientID: ${EXTERNAL_DNS_IDENTITY_CLIENT_ID:-}"
            ;;
        gcp)
            solver="      - dns01:
          cloudDNS:
            project: ${GCS_PROJECT_ID:-}"
            ;;
        upcloud)
            log_warn "UpCloud has no cert-manager DNS-01 solver; the platform uses Cloudflare."
            log_warn "Create the ClusterIssuer manually with a cloudflare solver and an API token secret."
            return 0
            ;;
    esac

    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-dns01
    solvers:
${solver}
EOF
    log_info "DNS-01 ClusterIssuer created (wildcard certificates)"
}

install_gateway() {
    log_step "Installing Envoy Gateway..."

    helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
        --namespace envoy-gateway-system \
        --create-namespace \
        --version "$CHART_ENVOY_GATEWAY" \
        -f "${BASE_DIR}/devops/gateway/values.yaml" \
        --atomic --timeout 10m

    kubectl wait --for=condition=Available deploy/envoy-gateway \
        -n envoy-gateway-system --timeout=300s || true

    log_info "Envoy Gateway installed"
}

# The Gateway itself, with a wildcard listener for application hostnames.
apply_gateway() {
    log_step "Applying the workload Gateway..."

    kubectl create namespace gateway 2>/dev/null || true

    local dir; dir="$(render_dir)"
    template_values "${BASE_DIR}/workload/gateway.yaml" "${dir}/gateway.yaml"
    kubectl apply -f "${dir}/gateway.yaml"

    log_info "Gateway applied — apps attach with sectionName: apps"
}

# Kyverno: app guardrails belong here, where the apps actually run. It enforces
# resource limits and registry restrictions, and generates the quota, limits and
# NetworkPolicies for each devhub-* namespace as ArgoCD creates it.
install_kyverno() {
    log_step "Installing Kyverno..."

    helm upgrade --install kyverno kyverno/kyverno \
        --namespace kyverno \
        --create-namespace \
        --version "$CHART_KYVERNO" \
        -f "${BASE_DIR}/devops/kyverno/values.yaml" \
        --atomic --timeout 10m

    kubectl wait --for=condition=Available deploy \
        -l app.kubernetes.io/component=admission-controller \
        -n kyverno --timeout=300s || true

    local dir; dir="$(render_dir)"
    template_values "${BASE_DIR}/devops/kyverno/policies.yaml" "${dir}/kyverno-policies.yaml"
    kubectl apply -f "${dir}/kyverno-policies.yaml"

    log_info "Kyverno installed with application policies"
}

# external-dns reuses the same per-cloud overlay values the platform cluster
# uses. The old inline config passed `provider: <cloud>`, which is not a valid
# provider name for GCP ("google") or UpCloud (no provider — Cloudflare is used),
# so those installs failed outright.
install_external_dns() {
    log_step "Installing external-dns..."

    local base_values="${BASE_DIR}/devops/external-dns/values.yaml"
    local cloud_values="${K8S_DIR}/overlays/${CLOUD}/devops/external-dns/values.yaml"
    local dir; dir="$(render_dir)"

    if [[ ! -f "$cloud_values" ]]; then
        log_error "No external-dns overlay for ${CLOUD}: ${cloud_values}"
        exit 1
    fi

    case "$CLOUD" in
        aws)   [[ -n "${EXTERNAL_DNS_IRSA_ROLE_ARN:-}" ]] || log_warn "EXTERNAL_DNS_IRSA_ROLE_ARN empty — run sync-tofu-outputs.sh" ;;
        azure) [[ -n "${EXTERNAL_DNS_IDENTITY_CLIENT_ID:-}" ]] || log_warn "EXTERNAL_DNS_IDENTITY_CLIENT_ID empty — run sync-tofu-outputs.sh" ;;
        gcp)   [[ -n "${EXTERNAL_DNS_GSA_EMAIL:-}" ]] || log_warn "EXTERNAL_DNS_GSA_EMAIL empty — run sync-tofu-outputs.sh" ;;
        upcloud)
            kubectl create namespace external-dns 2>/dev/null || true
            if ! kubectl get secret external-dns-cloudflare -n external-dns &>/dev/null; then
                log_warn "UpCloud has no external-dns provider; the overlay uses Cloudflare."
                log_warn "Create the token secret first:"
                log_warn "  kubectl create secret generic external-dns-cloudflare -n external-dns --from-literal=api-token=<token>"
            fi
            ;;
    esac

    template_values "$base_values" "${dir}/external-dns-base.yaml"
    template_values "$cloud_values" "${dir}/external-dns-cloud.yaml"

    kubectl create namespace external-dns 2>/dev/null || true

    helm upgrade --install external-dns external-dns/external-dns \
        --namespace external-dns \
        --version "$CHART_EXTERNAL_DNS" \
        -f "${dir}/external-dns-base.yaml" \
        -f "${dir}/external-dns-cloud.yaml" \
        --set txtOwnerId="${ENV}" \
        --atomic --timeout 5m

    log_info "external-dns installed (owner id: ${ENV})"
}

install_external_secrets() {
    log_step "Installing External Secrets Operator..."

    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets \
        --create-namespace \
        --version "$CHART_EXTERNAL_SECRETS" \
        --set installCRDs=true \
        --set global.priorityClassName=platform-standard \
        --atomic --timeout 5m

    log_info "External Secrets Operator installed"

    if [[ -z "${PLATFORM_VAULT_URL:-}" || "$PLATFORM_VAULT_URL" == *"example.com"* ]]; then
        log_warn "platformVaultUrl is unset or still a placeholder in ${CONFIG_FILE}"
        log_warn "Set it, then re-run: ./deploy-workload.sh --env ${ENV} external-secrets"
        return 0
    fi

    log_step "Creating ClusterSecretStore pointing at the platform Vault..."

    local dir; dir="$(render_dir)"
    template_values "${BASE_DIR}/workload/vault-cluster-secret-store.yaml" "${dir}/vault-cluster-secret-store.yaml"
    kubectl apply -f "${dir}/vault-cluster-secret-store.yaml"

    log_info "ClusterSecretStore created (Vault JWT auth, mount jwt-${ENV})"
    log_warn "The Vault side of this trust is created by:"
    log_warn "  ./register-workload-cluster.sh --env ${ENV}"
}

install_alloy() {
    log_step "Installing Grafana Alloy (log forwarding to the platform Loki)..."

    if [[ -z "${PLATFORM_LOKI_URL:-}" || "$PLATFORM_LOKI_URL" == *"example.com"* ]]; then
        log_warn "platformLokiUrl is unset or still a placeholder in ${CONFIG_FILE}"
        log_warn "Skipping Alloy. Set it and re-run: ./deploy-workload.sh --env ${ENV} alloy"
        return 0
    fi

    kubectl create namespace monitoring 2>/dev/null || true

    # Credentials for the platform Loki ingress. register-workload-cluster.sh
    # copies the real ones over; without them Alloy pushes unauthenticated and
    # every request is rejected.
    if ! kubectl get secret loki-ingest-credentials -n monitoring &>/dev/null; then
        log_warn "Secret monitoring/loki-ingest-credentials is missing — Alloy will fail to push."
        log_warn "Create it with: ./register-workload-cluster.sh --env ${ENV}"
        kubectl create secret generic loki-ingest-credentials -n monitoring \
            --from-literal=USERNAME=workload \
            --from-literal=PASSWORD=placeholder
    fi

    local dir; dir="$(render_dir)"
    # ENV is needed inside the rendered Alloy config (tenant + cluster label).
    export ENV
    envsubst '${PLATFORM_LOKI_URL} ${ENV}' \
        < "${BASE_DIR}/workload/alloy-values.yaml" > "${dir}/alloy-values.yaml"

    helm upgrade --install alloy grafana/alloy \
        --namespace monitoring \
        --version "$CHART_ALLOY" \
        -f "${dir}/alloy-values.yaml" \
        --atomic --timeout 5m

    log_info "Alloy installed (tenant: ${ENV} → ${PLATFORM_LOKI_URL})"
}

# =============================================================================
# Main
# =============================================================================

deploy_all() {
    log_phase "Deploying workload cluster platform components (env: ${ENV})"
    install_scheduling_policies
    install_storage_class
    install_gateway
    install_cert_manager
    apply_gateway
    install_external_dns
    install_external_secrets
    install_kyverno
    install_alloy

    echo ""
    log_info "Workload cluster deployment complete!"
    echo ""
    echo "  Next steps:"
    echo "  1. Register this cluster with the platform ArgoCD, create its Vault"
    echo "     trust and copy the Loki ingest credentials:"
    echo "       ./register-workload-cluster.sh --env ${ENV}"
    echo "  2. Push an app to the Forgejo devhub organisation — ArgoCD discovers and"
    echo "     deploys it here automatically."
    echo "  3. Nothing to re-run for new apps: Kyverno generates each namespace's"
    echo "     quota, limits and NetworkPolicies as ArgoCD creates it."
    echo ""
}

add_helm_repos
check_requirements
require_cluster_match

case "$COMPONENT" in
    all)                deploy_all ;;
    cert-manager)       install_cert_manager ;;
    gateway)            install_gateway && apply_gateway ;;
    kyverno)            install_kyverno ;;
    external-dns)       install_external_dns ;;
    external-secrets)   install_external_secrets ;;
    alloy)              install_alloy ;;
    storage)            install_storage_class ;;
    policies)           install_scheduling_policies ;;
    # Deprovision tail: sweep namespaces of deleted apps (dry-run unless "apply").
    cleanup-apps)       cleanup_orphaned_app_namespaces "${2:-dry-run}" ;;
    *)
        log_error "Unknown component: ${COMPONENT}"
        log_error "Valid: all, gateway, cert-manager, external-dns, external-secrets, kyverno, alloy, storage, policies, cleanup-apps"
        exit 1
        ;;
esac
