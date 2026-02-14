#!/bin/bash
set -euo pipefail

# =============================================================================
# Kubernetes Platform Deploy Script
# =============================================================================
# Deploys DevOps platform infrastructure to local or UpCloud environments.
# Applications are managed via ArgoCD GitOps (see k8s/argocd/).
#
# Usage: ./deploy.sh [local|upcloud] [component] [action]
#
# Components: all, devops, or specific services
# Actions: deploy (default), status, delete
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../.."
BASE_DIR="${K8S_DIR}/base"
ARGOCD_DIR="${K8S_DIR}/argocd"

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

# Defaults
ENV="${1:-local}"
COMPONENT="${2:-all}"
ACTION="${3:-deploy}"

# =============================================================================
# Parse config.yaml for environment-specific values
# =============================================================================
parse_config() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi
    
    # Parse YAML using grep/sed (no yq dependency)
    # Export as environment variables for envsubst
    export DOMAIN=$(grep -E '^domain:' "$config_file" | sed 's/domain:[[:space:]]*//')
    export TLS_SECRET_NAME=$(grep -E '^[[:space:]]*secretName:' "$config_file" | head -1 | sed 's/.*secretName:[[:space:]]*//')
    export TLS_TYPE=$(grep -E '^[[:space:]]*type:' "$config_file" | head -1 | sed 's/.*type:[[:space:]]*//')
    export ACME_EMAIL=$(grep -E '^acmeEmail:' "$config_file" | sed 's/acmeEmail:[[:space:]]*//')
    
    # Set defaults if empty
    TLS_SECRET_NAME="${TLS_SECRET_NAME:-local-tls-secret}"
    ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"
}

# Environment-specific configuration
case "$ENV" in
    local)
        OVERLAY_DIR="${K8S_DIR}/overlays/local"
        CERTS_DIR="${K8S_DIR}/certs"
        USE_CERT_MANAGER=false
        parse_config "${OVERLAY_DIR}/config.yaml"
        ;;
    upcloud)
        OVERLAY_DIR="${K8S_DIR}/overlays/upcloud"
        USE_CERT_MANAGER=true
        # Allow environment variable overrides for CI/CD
        if [[ -n "${DOMAIN:-}" ]]; then
            export DOMAIN
        else
            parse_config "${OVERLAY_DIR}/config.yaml"
        fi
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
        echo "  all        - Deploy entire platform (alias for devops)"
        echo "  devops     - DevOps platform"
        echo "  data-services, keycloak, vault, monitoring, gitlab, argocd - Individual components"
        echo "  bootstrap  - Deploy ArgoCD app-of-apps for GitOps"
        echo ""
        echo "Actions:"
        echo "  deploy     - Deploy (default)"
        echo "  status     - Show status"
        echo "  delete     - Delete resources"
        echo ""
        echo "Applications are managed via ArgoCD. See k8s/argocd/README.md"
        exit 1
        ;;
esac

# =============================================================================
# Common Functions
# =============================================================================

# Template overlay values with environment variables
# Usage: template_values <overlay-file> <output-file>
# Only substitutes known config variables, preserving other $variables
template_values() {
    local input="$1"
    local output="$2"
    envsubst '${DOMAIN} ${TLS_SECRET_NAME} ${CLUSTER_ISSUER} ${ACME_EMAIL}' < "$input" > "$output"
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
    
    if [[ -z "${DOMAIN:-}" ]]; then
        log_error "DOMAIN not set. Check config.yaml in overlay directory."
        exit 1
    fi
    
    if [[ "$ENV" == "local" && ! -f "${CERTS_DIR}/domains/local-dev.crt" ]]; then
        log_error "Certificates not found. Run: ./setup-ca.sh"
        exit 1
    fi
    
    log_info "Requirements satisfied (env: $ENV, domain: $DOMAIN)"
}

add_helm_repos() {
    command -v helm &>/dev/null || { log_error "helm required"; exit 1; }
    
    log_step "Adding Helm repositories..."
    
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo add codecentric https://codecentric.github.io/helm-charts 2>/dev/null || true
    helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
    helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo add gitlab https://charts.gitlab.io 2>/dev/null || true
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true

    helm repo update
    log_info "Helm repositories updated"
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
    
    for ns in data-services keycloak vault gitlab argocd monitoring; do
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

install_data_services() {
    log_step "Installing shared data services..."

    kubectl create namespace data-services 2>/dev/null || true

    local DATA_SERVICES_DIR="${OVERLAY_DIR}/data-services"

    # Generate PostgreSQL credentials if not exists
    if ! kubectl get secret postgresql-credentials -n data-services &>/dev/null; then
        local PG_ADMIN_PASSWORD=$(openssl rand -base64 24)
        local PG_KEYCLOAK_PASSWORD=$(openssl rand -base64 24)
        local PG_GITLAB_PASSWORD=$(openssl rand -base64 24)

        kubectl create secret generic postgresql-credentials -n data-services \
            --from-literal=postgres-password="$PG_ADMIN_PASSWORD" \
            --from-literal=keycloak-password="$PG_KEYCLOAK_PASSWORD" \
            --from-literal=gitlab-password="$PG_GITLAB_PASSWORD"

        # Create corresponding secrets in consuming namespaces
        kubectl create namespace keycloak 2>/dev/null || true
        kubectl create secret generic keycloak-db-secret -n keycloak \
            --from-literal=password="$PG_KEYCLOAK_PASSWORD" \
            --from-literal=postgres-password="$PG_ADMIN_PASSWORD" \
            2>/dev/null || true

        kubectl create namespace gitlab 2>/dev/null || true
        kubectl create secret generic gitlab-postgresql-secret -n gitlab \
            --from-literal=password="$PG_GITLAB_PASSWORD" \
            --from-literal=postgres-password="$PG_ADMIN_PASSWORD" \
            2>/dev/null || true

        # Update init SQL with actual passwords
        local INIT_SQL=$(kubectl get configmap postgresql-init -n data-services -o jsonpath='{.data.init\.sql}' 2>/dev/null || echo "")
        if [[ -z "$INIT_SQL" ]]; then
            cat <<EOSQL | kubectl create configmap postgresql-init -n data-services --from-file=init.sql=/dev/stdin
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') THEN
    CREATE ROLE keycloak WITH LOGIN PASSWORD '${PG_KEYCLOAK_PASSWORD}';
  END IF;
END \$\$;
CREATE DATABASE keycloak OWNER keycloak;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gitlab') THEN
    CREATE ROLE gitlab WITH LOGIN PASSWORD '${PG_GITLAB_PASSWORD}';
  END IF;
END \$\$;
CREATE DATABASE gitlab OWNER gitlab;

\c gitlab
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;
EOSQL
        fi
    else
        log_info "PostgreSQL credentials already exist"
    fi

    # Generate Valkey credentials if not exists
    if ! kubectl get secret valkey-credentials -n data-services &>/dev/null; then
        local VALKEY_PASSWORD=$(openssl rand -base64 24)

        kubectl create secret generic valkey-credentials -n data-services \
            --from-literal=password="$VALKEY_PASSWORD"

        # Create corresponding secret in gitlab namespace
        kubectl create namespace gitlab 2>/dev/null || true
        kubectl create secret generic gitlab-redis-secret -n gitlab \
            --from-literal=password="$VALKEY_PASSWORD" \
            2>/dev/null || true
    else
        log_info "Valkey credentials already exist"
    fi

    # Generate MinIO credentials if not exists
    if ! kubectl get secret minio-credentials -n data-services &>/dev/null; then
        local MINIO_ACCESS_KEY=$(openssl rand -hex 16)
        local MINIO_SECRET_KEY=$(openssl rand -base64 32)

        kubectl create secret generic minio-credentials -n data-services \
            --from-literal=access-key="$MINIO_ACCESS_KEY" \
            --from-literal=secret-key="$MINIO_SECRET_KEY"

        # Create GitLab object storage secret (S3 connection YAML)
        kubectl create namespace gitlab 2>/dev/null || true

        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-object-storage-secret
  namespace: gitlab
type: Opaque
stringData:
  connection: |
    provider: AWS
    aws_access_key_id: "${MINIO_ACCESS_KEY}"
    aws_secret_access_key: "${MINIO_SECRET_KEY}"
    region: us-east-1
    endpoint: "http://minio.data-services.svc.cluster.local:9000"
    path_style: true
EOF

        # Create GitLab registry storage secret
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-registry-storage-secret
  namespace: gitlab
type: Opaque
stringData:
  config: |
    s3:
      accesskey: "${MINIO_ACCESS_KEY}"
      secretkey: "${MINIO_SECRET_KEY}"
      region: us-east-1
      regionendpoint: "http://minio.data-services.svc.cluster.local:9000"
      bucket: gitlab-registry
      v4auth: true
EOF
    else
        log_info "MinIO credentials already exist"
    fi

    # Deploy PostgreSQL (apply manifest, skip configmap since we created it with passwords)
    log_info "Deploying PostgreSQL..."
    kubectl apply -f "${DATA_SERVICES_DIR}/postgresql.yaml"

    # Deploy Valkey
    log_info "Deploying Valkey..."
    kubectl apply -f "${DATA_SERVICES_DIR}/valkey.yaml"

    # Deploy MinIO
    log_info "Deploying MinIO..."
    kubectl apply -f "${DATA_SERVICES_DIR}/minio.yaml"

    # Wait for data services to be ready
    log_info "Waiting for data services to be ready..."
    kubectl wait --for=condition=ready pod -l app=postgresql -n data-services --timeout=120s || true
    kubectl wait --for=condition=ready pod -l app=valkey -n data-services --timeout=120s || true
    kubectl wait --for=condition=ready pod -l app=minio -n data-services --timeout=120s || true

    log_info "Shared data services installed"
}

install_keycloak() {
    log_step "Installing Keycloak..."

    kubectl create namespace keycloak 2>/dev/null || true

    # Create admin credentials secret if not exists
    if ! kubectl get secret keycloak-admin-secret -n keycloak &>/dev/null; then
        local ADMIN_PASSWORD=$(openssl rand -base64 24)
        kubectl create secret generic keycloak-admin-secret -n keycloak \
            --from-literal=KEYCLOAK_ADMIN=admin \
            --from-literal=KEYCLOAK_ADMIN_PASSWORD="$ADMIN_PASSWORD"
    fi

    # keycloak-db-secret is created by install_data_services()

    local values_args=$(get_values_args "keycloak")

    helm upgrade --install keycloak codecentric/keycloakx \
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
}

install_external_secrets() {
    log_step "Installing External Secrets..."
    
    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets \
        --create-namespace \
        -f "${BASE_DIR}/devops/external-secrets/values.yaml" \
        --wait --timeout 10m
    
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

    # Create placeholder OIDC secret so Grafana can start before Keycloak SSO is configured
    # setup-keycloak.sh will update this with the real client secret later
    if ! kubectl get secret grafana-oidc-secret -n monitoring &>/dev/null; then
        kubectl create secret generic grafana-oidc-secret -n monitoring \
            --from-literal=client-secret="placeholder"
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

    # Create placeholder OIDC secret so GitLab pods can mount volumes before Keycloak SSO is configured
    # setup-keycloak.sh will update this with the real client secret later
    if ! kubectl get secret gitlab-oidc-secret -n gitlab &>/dev/null; then
        kubectl create secret generic gitlab-oidc-secret -n gitlab \
            --from-literal=provider='{"name":"openid_connect","label":"Keycloak","args":{"name":"openid_connect","scope":["openid","profile","email"],"response_type":"code","issuer":"https://keycloak.localhost/realms/devops","discovery":true,"client_auth_method":"query","uid_field":"preferred_username","client_options":{"identifier":"gitlab","secret":"placeholder","redirect_uri":"https://gitlab.localhost/users/auth/openid_connect/callback"}}}'
    fi

    local values_args=$(get_values_args "gitlab")
    
    helm upgrade --install gitlab gitlab/gitlab \
        --namespace gitlab \
        $values_args \
        --wait \
        --timeout 30m
    
    log_info "GitLab installed"
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

bootstrap_argocd_apps() {
    log_step "Bootstrapping ArgoCD app-of-apps..."
    
    # Apply ArgoCD project
    kubectl apply -f "${ARGOCD_DIR}/projects/tshub.yaml"
    
    # Apply app-of-apps (this will sync all applications in argocd/apps/)
    kubectl apply -f "${ARGOCD_DIR}/apps/app-of-apps.yaml"
    
    log_info "ArgoCD app-of-apps deployed"
    log_info "Applications will be managed via GitOps. Add manifests to k8s/argocd/apps/"
}

apply_devops_ingress() {
    log_step "Applying DevOps ingress..."
    
    # Template ingress.yaml with environment variables and apply
    local ingress_file="${OVERLAY_DIR}/devops/ingress.yaml"
    local templated_ingress="/tmp/devops-ingress.yaml"
    
    envsubst < "$ingress_file" > "$templated_ingress"
    kubectl apply -f "$templated_ingress"
    
    log_info "DevOps ingress applied"
}

ensure_nginx_ingress() {
    if [[ "$ENV" != "local" ]]; then return 0; fi

    # Check if already installed and running
    if helm list -n ingress-nginx 2>/dev/null | grep -q ingress-nginx; then
        log_info "nginx-ingress already installed"
        return 0
    fi

    log_step "Installing nginx-ingress controller..."

    # Remove Traefik if present (Rancher Desktop default) to free ports 80/443
    if helm list -n kube-system 2>/dev/null | grep -q traefik; then
        log_info "Removing Traefik to free ports 80/443..."
        helm uninstall traefik -n kube-system 2>/dev/null || true
        helm uninstall traefik-crd -n kube-system 2>/dev/null || true
        sleep 5
    fi

    # Ensure tshub namespace and TLS secret exist (needed for default-ssl-certificate)
    kubectl create namespace tshub 2>/dev/null || true
    local CERT_B64=$(base64 -w 0 "${CERTS_DIR}/domains/local-dev.crt")
    local KEY_B64=$(base64 -w 0 "${CERTS_DIR}/domains/local-dev.key")
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: local-tls-secret
  namespace: tshub
type: kubernetes.io/tls
data:
  tls.crt: ${CERT_B64}
  tls.key: ${KEY_B64}
EOF

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

    # Wait for controller to be ready
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=120s

    log_info "nginx-ingress controller installed"
}

deploy_devops() {
    add_helm_repos
    ensure_nginx_ingress
    create_devops_namespaces
    [[ "$ENV" == "local" ]] && copy_tls_secrets
    install_cert_manager
    install_data_services  # Shared PostgreSQL, Valkey, MinIO
    install_monitoring     # Install early - provides ServiceMonitor CRDs
    install_keycloak
    install_vault
    install_external_secrets
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
    # Clean up legacy per-service PostgreSQL (if migrating from old layout)
    kubectl delete statefulset keycloak-postgresql -n keycloak 2>/dev/null || true
    kubectl delete service keycloak-postgresql -n keycloak 2>/dev/null || true
    kubectl delete pvc keycloak-postgresql-pvc -n keycloak 2>/dev/null || true
    helm uninstall external-secrets -n external-secrets 2>/dev/null || true
    helm uninstall cert-manager -n cert-manager 2>/dev/null || true

    # Delete shared data services
    kubectl delete -f "${OVERLAY_DIR}/data-services/minio.yaml" 2>/dev/null || true
    kubectl delete -f "${OVERLAY_DIR}/data-services/valkey.yaml" 2>/dev/null || true
    kubectl delete -f "${OVERLAY_DIR}/data-services/postgresql.yaml" 2>/dev/null || true

    kubectl delete -k "${OVERLAY_DIR}/devops" 2>/dev/null || true

    log_info "DevOps platform deleted"
}

status_devops() {
    log_step "DevOps Platform Status:"
    echo ""
    for ns in data-services keycloak vault gitlab argocd monitoring external-secrets cert-manager; do
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
    echo "Applications:"
    echo "  Apps are managed via ArgoCD GitOps."
    echo "  Add Application manifests to: k8s/argocd/apps/"
    echo "  Bootstrap with: ./deploy.sh ${ENV} bootstrap"
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
                all|devops)
                    deploy_devops
                    print_summary
                    ;;
                bootstrap)
                    bootstrap_argocd_apps
                    ;;
                data-services)
                    install_data_services
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
                    apply_devops_ingress
                    ;;
                *)
                    log_error "Unknown component: $COMPONENT"
                    exit 1
                    ;;
            esac
            ;;
        status)
            status_devops
            ;;
        delete)
            case "$COMPONENT" in
                all|devops)
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
