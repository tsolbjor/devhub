#!/bin/bash
set -euo pipefail

# =============================================================================
# Workload Cluster Deploy Script
# =============================================================================
# Installs the minimal platform components on a workload cluster:
#   - cert-manager (TLS certificate management)
#   - nginx-ingress (Ingress controller)
#   - external-dns (Automatic DNS record management)
#   - external-secrets (Pull secrets from Vault on the platform cluster)
#   - grafana-alloy (Log forwarding to Loki on the platform cluster)
#
# The workload cluster runs application workloads only. Keycloak, Vault,
# GitLab, ArgoCD, and monitoring stack live on the platform cluster.
# ArgoCD on the platform cluster deploys apps here via the app-of-apps pattern.
#
# Usage:
#   ./deploy-workload.sh --env aws-workload|azure-workload|gcp-workload|upcloud-workload
#   ./deploy-workload.sh --env aws-workload <component>
#
# Components: all (default), cert-manager, ingress, external-dns, external-secrets, alloy
#
# Prerequisites:
#   - sync-tofu-outputs.sh --env <workload-env> has been run
#   - KUBECONFIG points to the workload cluster
#   - Vault is running on the platform cluster
#   - Register with platform ArgoCD: ./register-workload-cluster.sh --env <workload-env>
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
set -- "${ARGS[@]}"

COMPONENT="${1:-all}"

# Validate this is a workload env
case "$ENV" in
    aws-workload|azure-workload|gcp-workload|upcloud-workload) ;;
    *)
        log_error "deploy-workload.sh is for workload environments only"
        log_error "Valid: aws-workload, azure-workload, gcp-workload, upcloud-workload"
        log_error "For platform clusters, use: ./deploy.sh --env ${ENV}"
        exit 1
        ;;
esac

# Determine cloud from env name
CLOUD="${ENV%-workload}"

setup_paths
parse_config

add_helm_repos
check_requirements

CONFIG_FILE="${OVERLAY_DIR}/config.yaml"

# =============================================================================
# Component Install Functions
# =============================================================================

install_cert_manager() {
    log_step "Installing cert-manager..."

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.20.1 \
        --set crds.enabled=true \
        --atomic --timeout 5m

    log_info "cert-manager installed"

    # Create ClusterIssuer for Let's Encrypt
    log_step "Creating Let's Encrypt ClusterIssuer..."
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
          ingress:
            ingressClassName: nginx
EOF
    log_info "ClusterIssuer created"
}

install_ingress() {
    log_step "Installing nginx-ingress controller..."

    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --version 4.15.1 \
        --set controller.replicaCount=2 \
        --set controller.metrics.enabled=true \
        --set controller.podAnnotations."prometheus\.io/scrape"=true \
        --set controller.podAnnotations."prometheus\.io/port"=10254 \
        --atomic --timeout 5m

    log_info "nginx-ingress installed"
}

install_external_dns() {
    log_step "Installing external-dns..."

    EDNS_VALUES=$(mktemp /tmp/external-dns-workload-values.XXXXXX.yaml)
    trap "rm -f ${EDNS_VALUES}" RETURN

    cat > "$EDNS_VALUES" <<EOF
provider:
  name: ${CLOUD}
txtOwnerId: ${ENV}
domainFilters:
  - ${DOMAIN}
policy: sync
sources:
  - ingress
EOF

    if [[ "$CLOUD" == "aws" ]]; then
        if [[ -z "${EXTERNAL_DNS_IRSA_ROLE_ARN:-}" ]]; then
            log_warn "EXTERNAL_DNS_IRSA_ROLE_ARN not set — run sync-tofu-outputs.sh --env ${ENV} first"
        fi
        cat >> "$EDNS_VALUES" <<EOF
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: "${EXTERNAL_DNS_IRSA_ROLE_ARN:-}"
EOF

    elif [[ "$CLOUD" == "azure" ]]; then
        if [[ -z "${EXTERNAL_DNS_IDENTITY_CLIENT_ID:-}" ]]; then
            log_warn "EXTERNAL_DNS_IDENTITY_CLIENT_ID not set — run sync-tofu-outputs.sh --env ${ENV} first"
        fi
        cat >> "$EDNS_VALUES" <<EOF
serviceAccount:
  annotations:
    azure.workload.identity/client-id: "${EXTERNAL_DNS_IDENTITY_CLIENT_ID:-}"
podLabels:
  azure.workload.identity/use: "true"
EOF

    elif [[ "$CLOUD" == "gcp" ]]; then
        if [[ -z "${EXTERNAL_DNS_GSA_EMAIL:-}" ]]; then
            log_warn "EXTERNAL_DNS_GSA_EMAIL not set — run sync-tofu-outputs.sh --env ${ENV} first"
        fi
        cat >> "$EDNS_VALUES" <<EOF
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: "${EXTERNAL_DNS_GSA_EMAIL:-}"
EOF
    fi

    helm upgrade --install external-dns external-dns/external-dns \
        --namespace external-dns \
        --create-namespace \
        --version 1.20.0 \
        -f "$EDNS_VALUES" \
        --atomic --timeout 5m

    log_info "external-dns installed"
}

install_external_secrets() {
    log_step "Installing External Secrets Operator..."

    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets \
        --create-namespace \
        --version 2.3.0 \
        --set installCRDs=true \
        --atomic --timeout 5m

    log_info "External Secrets Operator installed"

    if [[ -z "${PLATFORM_VAULT_URL:-}" || "$PLATFORM_VAULT_URL" == "https://vault.example.com" || "$PLATFORM_VAULT_URL" == *"example.com"* ]]; then
        log_warn "platformVaultUrl not configured in ${CONFIG_FILE}"
        log_warn "Update it to your platform Vault URL, then create the ClusterSecretStore manually:"
        log_warn "  kubectl apply -f <(cat k8s/base/workload/vault-cluster-secret-store.yaml | VAULT_URL=https://vault.DOMAIN envsubst)"
        log_warn "Or re-run: ./deploy-workload.sh --env ${ENV} external-secrets"
        return 0
    fi

    log_step "Creating ClusterSecretStore pointing to platform Vault..."

    # The Vault token secret is created by register-workload-cluster.sh
    cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "${PLATFORM_VAULT_URL}"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-workload-token
          namespace: external-secrets
          key: token
EOF
    log_info "ClusterSecretStore created"
    log_warn "Vault token secret 'vault-workload-token' must exist in namespace 'external-secrets'"
    log_warn "Run: ./register-workload-cluster.sh --env ${ENV} to create it automatically"
}

install_alloy() {
    log_step "Installing Grafana Alloy (log forwarding to platform Loki)..."

    if [[ -z "${PLATFORM_VAULT_URL:-}" || "$PLATFORM_VAULT_URL" == *"example.com"* ]]; then
        log_warn "platformVaultUrl not configured — cannot derive Loki URL"
        log_warn "Skipping Alloy install. Set platformVaultUrl in ${CONFIG_FILE} and re-run."
        return 0
    fi

    # Derive Loki URL from Vault URL (same domain, different service)
    LOKI_URL="${PLATFORM_VAULT_URL/vault/loki}"

    # Write Alloy River config to a temp file
    ALLOY_VALUES=$(mktemp /tmp/alloy-workload-values.XXXXXX.yaml)
    trap "rm -f ${ALLOY_VALUES}" RETURN

    cat > "$ALLOY_VALUES" <<EOF
controller:
  type: daemonset

alloy:
  mounts:
    varlog: true
  configMap:
    create: true
    content: |
      discovery.kubernetes "pods" {
        role = "pod"
      }

      discovery.relabel "pod_logs" {
        targets = discovery.kubernetes.pods.targets
        rule {
          source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
          separator     = "/"
          target_label  = "__path__"
          replacement   = "/var/log/pods/\$1/*.log"
        }
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_phase"]
          regex         = "Pending|Succeeded|Failed|Unknown"
          action        = "drop"
        }
      }

      loki.source.file "pod_logs" {
        targets    = discovery.relabel.pod_logs.output
        forward_to = [loki.process.parse.receiver]
      }

      loki.process "parse" {
        stage.cri {}
        stage.label_drop { values = ["filename", "stream"] }
        forward_to = [loki.write.platform.receiver]
      }

      loki.write "platform" {
        endpoint {
          url       = "${LOKI_URL}/loki/api/v1/push"
          tenant_id = "${ENV}"
        }
      }

tolerations:
  - operator: Exists
EOF

    helm upgrade --install alloy grafana/alloy \
        --namespace monitoring \
        --create-namespace \
        --version 1.7.0 \
        -f "$ALLOY_VALUES" \
        --atomic --timeout 5m

    log_info "Alloy installed (forwarding logs to: ${LOKI_URL})"
}

# =============================================================================
# Main
# =============================================================================

case "$COMPONENT" in
    all)
        log_phase "Deploying workload cluster platform components (env: ${ENV})"
        install_cert_manager
        install_ingress
        install_external_dns
        install_external_secrets
        install_alloy
        echo ""
        log_info "Workload cluster deployment complete!"
        echo ""
        echo "  Next steps:"
        echo "  1. Register this cluster with platform ArgoCD:"
        echo "     ./register-workload-cluster.sh --env ${ENV}"
        echo "  2. Create a deploy token in GitLab for the workload cluster to pull images"
        echo "     (handled by register-workload-cluster.sh)"
        echo ""
        ;;
    cert-manager)  install_cert_manager ;;
    ingress)       install_ingress ;;
    external-dns)  install_external_dns ;;
    external-secrets) install_external_secrets ;;
    alloy)         install_alloy ;;
    *)
        log_error "Unknown component: ${COMPONENT}"
        log_error "Valid: all, cert-manager, ingress, external-dns, external-secrets, alloy"
        exit 1
        ;;
esac
