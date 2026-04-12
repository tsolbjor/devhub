#!/bin/bash
set -euo pipefail

# =============================================================================
# Kubernetes Platform Deploy Script
# =============================================================================
# Deploys DevOps platform infrastructure to local or UpCloud environments.
# Applications are managed via ArgoCD GitOps (see k8s/argocd/).
#
# Usage: ./deploy.sh --env local|upcloud-dev|upcloud-prod [component] [action]
#
# Components: all, devops, or specific services
# Actions: deploy (default), status, delete
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Parse --env and remaining args
parse_env_arg "$@"
set -- "${ARGS[@]}"

COMPONENT="${1:-all}"
ACTION="${2:-deploy}"

# Set up paths and parse config
setup_paths
parse_config

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

    for ns in data-services keycloak vault gitlab argocd monitoring headlamp; do
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
        --version v1.20.1 \
        -f "${BASE_DIR}/devops/cert-manager/values.yaml" \
        --atomic --timeout 5m

    kubectl wait --for=condition=ready pod -l app=webhook -n cert-manager --timeout=60s

    # Apply cluster issuers with templated email
    envsubst < "${BASE_DIR}/devops/cert-manager/cluster-issuers.yaml" | kubectl apply -f -

    log_info "cert-manager installed"
}

install_data_services() {
    if [[ "$DATA_SERVICES_TYPE" == "managed" ]]; then
        configure_managed_data_services
        return 0
    fi

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

    # Deploy PostgreSQL
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

configure_managed_data_services() {
    log_step "Configuring managed data services..."

    if [[ -z "${PG_HOST:-}" ]]; then
        log_warn "PG_HOST not set — update dataServices.postgresql.host in config.yaml"
    fi
    if [[ -z "${VALKEY_HOST:-}" ]]; then
        log_warn "VALKEY_HOST not set — update dataServices.valkey.host in config.yaml"
    fi
    if [[ -z "${S3_ENDPOINT:-}" ]]; then
        log_warn "S3_ENDPOINT not set — update dataServices.s3.endpoint in config.yaml"
    fi

    local missing_secrets=()

    kubectl create namespace keycloak 2>/dev/null || true
    kubectl create namespace gitlab 2>/dev/null || true

    if ! kubectl get secret keycloak-db-secret -n keycloak &>/dev/null; then
        missing_secrets+=("keycloak-db-secret -n keycloak (keys: password)")
    fi
    if ! kubectl get secret gitlab-postgresql-secret -n gitlab &>/dev/null; then
        missing_secrets+=("gitlab-postgresql-secret -n gitlab (keys: password, postgres-password)")
    fi
    if ! kubectl get secret gitlab-redis-secret -n gitlab &>/dev/null; then
        missing_secrets+=("gitlab-redis-secret -n gitlab (keys: password)")
    fi
    if ! kubectl get secret gitlab-object-storage-secret -n gitlab &>/dev/null; then
        missing_secrets+=("gitlab-object-storage-secret -n gitlab (keys: connection)")
    fi
    if ! kubectl get secret gitlab-registry-storage-secret -n gitlab &>/dev/null; then
        missing_secrets+=("gitlab-registry-storage-secret -n gitlab (keys: config)")
    fi

    if [[ ${#missing_secrets[@]} -gt 0 ]]; then
        log_warn "The following secrets must be created before deploying:"
        for s in "${missing_secrets[@]}"; do
            log_warn "  kubectl create secret generic $s"
        done
        log_warn "Services will fail to start without these secrets."
    fi

    log_info "Managed data services configured"
}

install_keycloak() {
    log_step "Installing Keycloak..."

    kubectl create namespace keycloak 2>/dev/null || true

    # RBAC for JGroups KUBE_PING pod discovery (required for --cache-stack=kubernetes)
    kubectl apply -f "${BASE_DIR}/devops/keycloak/rbac.yaml"

    # Create admin credentials secret if not exists
    if ! kubectl get secret keycloak-admin-secret -n keycloak &>/dev/null; then
        local ADMIN_PASSWORD=$(openssl rand -base64 24)
        kubectl create secret generic keycloak-admin-secret -n keycloak \
            --from-literal=KEYCLOAK_ADMIN=admin \
            --from-literal=KEYCLOAK_ADMIN_PASSWORD="$ADMIN_PASSWORD"
    fi

    local values_args=$(get_values_args "keycloak")

    helm upgrade --install keycloak codecentric/keycloakx \
        --namespace keycloak \
        --version 7.1.9 \
        $values_args \
        --atomic --timeout 10m

    log_info "Keycloak installed"
}

install_vault() {
    log_step "Installing Vault..."

    kubectl create namespace vault 2>/dev/null || true

    local values_args=$(get_values_args "vault")

    # Apply cloud KMS auto-unseal overlay if the required variables are configured.
    # See overlays/{cloud}/devops/vault/vault-autounseal-values.yaml for setup instructions.
    local autounseal_overlay="${OVERLAY_DIR}/devops/vault/vault-autounseal-values.yaml"
    if [[ -f "$autounseal_overlay" ]]; then
        local apply_autounseal=false
        case "$ENV" in
            aws-*)   [[ -n "${VAULT_KMS_KEY_ID:-}" ]]    && apply_autounseal=true ;;
            azure-*) [[ -n "${VAULT_KEY_VAULT_NAME:-}" ]] && apply_autounseal=true ;;
            gcp-*)   [[ -n "${VAULT_KMS_KEY_RING:-}" ]]   && apply_autounseal=true ;;
        esac
        if $apply_autounseal; then
            template_values "$autounseal_overlay" "/tmp/vault-autounseal-values.yaml"
            values_args="$values_args -f /tmp/vault-autounseal-values.yaml"
            log_info "Vault auto-unseal (cloud KMS) enabled"
        else
            log_warn "Vault KMS variables not set — running with manual unseal"
            log_warn "See ${autounseal_overlay} for setup instructions"
        fi
    fi

    helm upgrade --install vault hashicorp/vault \
        --namespace vault \
        --version 0.32.0 \
        $values_args \
        --atomic --timeout 5m

    log_info "Vault installed"
}

install_external_dns() {
    if [[ "$ENV" == "local" ]]; then
        log_info "Skipping external-dns (not needed for local)"
        return 0
    fi

    log_step "Installing external-dns..."

    local values_args=$(get_values_args "external-dns")

    helm upgrade --install external-dns external-dns/external-dns \
        --namespace external-dns \
        --create-namespace \
        --version 1.20.0 \
        $values_args \
        --atomic --timeout 5m

    log_info "external-dns installed"
}

install_external_secrets() {
    log_step "Installing External Secrets..."

    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets \
        --create-namespace \
        --version 2.3.0 \
        -f "${BASE_DIR}/devops/external-secrets/values.yaml" \
        --atomic --timeout 10m

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
        --version 83.4.0 \
        $prom_args \
        --atomic --timeout 10m

    # Loki: apply cloud object-storage overlay if present (and WI/IRSA vars are set)
    local loki_args="-f ${BASE_DIR}/devops/monitoring/loki-values.yaml"
    local loki_overlay="${OVERLAY_DIR}/devops/monitoring/loki-values.yaml"
    if [[ -f "$loki_overlay" ]]; then
        local apply_loki_overlay=false
        case "$ENV" in
            aws-*)   [[ -n "${LOKI_IRSA_ROLE_ARN:-}" ]]        && apply_loki_overlay=true ;;
            azure-*) [[ -n "${LOKI_IDENTITY_CLIENT_ID:-}" ]]    && apply_loki_overlay=true ;;
            gcp-*)   [[ -n "${LOKI_GSA_EMAIL:-}" ]]             && apply_loki_overlay=true ;;
        esac
        if $apply_loki_overlay; then
            template_values "$loki_overlay" "/tmp/loki-overlay-values.yaml"
            loki_args="$loki_args -f /tmp/loki-overlay-values.yaml"
            log_info "Loki cloud object storage enabled"
        else
            log_warn "Loki WI/IRSA variables not set — using filesystem storage"
            log_warn "See ${loki_overlay} for setup instructions"
        fi
    fi

    helm upgrade --install loki grafana/loki \
        --namespace monitoring \
        --version 6.55.0 \
        $loki_args \
        --atomic --timeout 10m

    helm upgrade --install tempo grafana/tempo \
        --namespace monitoring \
        --version 1.24.4 \
        -f "${BASE_DIR}/devops/monitoring/tempo-values.yaml" \
        --atomic --timeout 5m

    helm upgrade --install alloy grafana/alloy \
        --namespace monitoring \
        --version 1.7.0 \
        -f "${BASE_DIR}/devops/monitoring/alloy-values.yaml" \
        --atomic --timeout 5m

    # Remove legacy promtail release if it still exists (replaced by Alloy)
    if helm status promtail -n monitoring &>/dev/null; then
        log_info "Removing legacy promtail release (replaced by Alloy)..."
        helm uninstall promtail -n monitoring
    fi

    log_info "Monitoring stack installed"
}

install_gitlab() {
    log_step "Installing GitLab CE..."

    kubectl create namespace gitlab 2>/dev/null || true

    # Runner cache PVC (referenced in gitlab/values.yaml runner config)
    kubectl apply -f "${BASE_DIR}/devops/gitlab/runner-cache-pvc.yaml"

    # Create placeholder OIDC secret so GitLab pods can mount volumes before Keycloak SSO is configured
    if ! kubectl get secret gitlab-oidc-secret -n gitlab &>/dev/null; then
        kubectl create secret generic gitlab-oidc-secret -n gitlab \
            --from-literal=provider='{"name":"openid_connect","label":"Keycloak","args":{"name":"openid_connect","scope":["openid","profile","email"],"response_type":"code","issuer":"https://keycloak.'"${DOMAIN}"'/realms/devops","discovery":true,"client_auth_method":"query","uid_field":"preferred_username","client_options":{"identifier":"gitlab","secret":"placeholder","redirect_uri":"https://gitlab.'"${DOMAIN}"'/users/auth/openid_connect/callback"}}}'
    fi

    local values_args=$(get_values_args "gitlab")

    helm upgrade --install gitlab gitlab/gitlab \
        --namespace gitlab \
        --version 9.10.3 \
        $values_args \
        --atomic --timeout 30m

    log_info "GitLab installed"
}

install_crossplane() {
    log_step "Installing Crossplane..."

    kubectl create namespace crossplane-system 2>/dev/null || true

    local values_args=$(get_values_args "crossplane")

    helm upgrade --install crossplane crossplane-stable/crossplane \
        --namespace crossplane-system \
        --version 2.2.0 \
        $values_args \
        --atomic --timeout 5m

    # Wait for core pods to be ready
    kubectl wait --for=condition=ready pod -l app=crossplane -n crossplane-system --timeout=120s 2>/dev/null || true

    # Install UpCloud provider
    log_info "Applying UpCloud provider..."
    kubectl apply -f "${BASE_DIR}/crossplane/provider-upcloud.yaml"

    # Wait for provider to become healthy (up to 5 minutes)
    log_info "Waiting for UpCloud provider to become healthy..."
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        local healthy=$(kubectl get providers.pkg.crossplane.io provider-upcloud -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null || echo "")
        if [[ "$healthy" == "True" ]]; then
            log_info "UpCloud provider is healthy"
            break
        fi
        attempts=$((attempts + 1))
        sleep 10
    done

    if [[ $attempts -ge $max_attempts ]]; then
        log_warn "UpCloud provider not yet healthy after 5 minutes — it may still be pulling the image"
    fi

    # Apply ProviderConfig only if the credentials secret exists
    if kubectl get secret upcloud-api-credentials -n crossplane-system &>/dev/null; then
        kubectl apply -f "${BASE_DIR}/crossplane/provider-config.yaml"
        log_info "ProviderConfig applied"
    else
        log_warn "Secret 'upcloud-api-credentials' not found in crossplane-system"
        log_warn "Create it before using Crossplane to provision UpCloud resources:"
        log_warn "  kubectl create secret generic upcloud-api-credentials -n crossplane-system \\"
        log_warn "    --from-literal=credentials='{\"username\":\"...\",\"password\":\"...\"}'"
    fi

    log_info "Crossplane installed"
}

install_argocd() {
    log_step "Installing ArgoCD..."

    kubectl create namespace argocd 2>/dev/null || true

    local values_args=$(get_values_args "argocd")

    # For local env, add hostAliases so ArgoCD server can reach keycloak.localhost
    # (glibc resolves *.localhost to 127.0.0.1 before querying DNS)
    local extra_args=""
    if [[ "$ENV" == "local" ]]; then
        local ingress_ip
        ingress_ip=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null) || true
        if [[ -n "$ingress_ip" ]]; then
            extra_args="--set global.hostAliases[0].ip=${ingress_ip} --set global.hostAliases[0].hostnames[0]=keycloak.${DOMAIN}"
            log_info "ArgoCD server hostAlias: keycloak.${DOMAIN} -> ${ingress_ip}"
        else
            log_warn "Could not resolve ingress-nginx ClusterIP - ArgoCD OIDC may not work"
        fi
    fi

    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        --version 9.5.0 \
        $values_args $extra_args \
        --atomic --timeout 5m

    log_info "ArgoCD installed"
}

bootstrap_argocd_apps() {
    log_step "Bootstrapping ArgoCD app-of-apps..."

    # Apply all ArgoCD projects
    for f in "${ARGOCD_DIR}"/projects/*.yaml; do
        [[ -f "$f" ]] && kubectl apply -f "$f"
    done

    # Apply app-of-apps (it auto-discovers ApplicationSets and other apps)
    kubectl apply -f "${ARGOCD_DIR}/apps/app-of-apps.yaml"

    log_info "ArgoCD app-of-apps deployed"
    log_info "Applications will be managed via GitOps. Add manifests to k8s/argocd/apps/"
}

apply_devops_ingress() {
    log_step "Applying DevOps ingress..."

    local ingress_file="${OVERLAY_DIR}/devops/ingress.yaml"
    local templated_ingress="/tmp/devops-ingress.yaml"

    template_values "$ingress_file" "$templated_ingress"
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

    # Ensure devhub namespace and TLS secret exist (needed for default-ssl-certificate)
    kubectl create namespace devhub 2>/dev/null || true
    local CERT_B64=$(base64 -w 0 "${CERTS_DIR}/domains/local-dev.crt")
    local KEY_B64=$(base64 -w 0 "${CERTS_DIR}/domains/local-dev.key")
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: local-tls-secret
  namespace: devhub
type: kubernetes.io/tls
data:
  tls.crt: ${CERT_B64}
  tls.key: ${KEY_B64}
EOF

    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --version 4.15.1 \
        --set controller.service.type=LoadBalancer \
        --set controller.service.externalTrafficPolicy=Local \
        --set controller.config.proxy-body-size="100m" \
        --set controller.config.ssl-redirect="true" \
        --set controller.config.use-forwarded-headers="true" \
        --set controller.config.compute-full-forwarded-for="true" \
        --set controller.config.use-proxy-protocol="false" \
        --set controller.extraArgs.default-ssl-certificate="devhub/local-tls-secret" \
        --set controller.admissionWebhooks.enabled=false \
        --timeout 5m

    # Wait for controller to be ready
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=120s

    log_info "nginx-ingress controller installed"
}

install_headlamp() {
    log_step "Installing Headlamp..."

    kubectl create namespace headlamp 2>/dev/null || true

    # Copy local TLS secret when running as a standalone install (deploy_devops copies it for full deploys)
    if [[ "$ENV" == "local" ]] && ! kubectl get secret local-tls-secret -n headlamp &>/dev/null; then
        kubectl create secret tls local-tls-secret -n headlamp \
            --cert="${CERTS_DIR}/domains/local-dev.crt" \
            --key="${CERTS_DIR}/domains/local-dev.key"
    fi

    # Apply RBAC for Headlamp's in-cluster ServiceAccount
    kubectl apply -f "${BASE_DIR}/devops/headlamp/rbac.yaml"

    # Create placeholder OIDC secret so Headlamp can start before Keycloak SSO is configured.
    # Use internal K8s service URL for issuerURL so the Headlamp backend can reach Keycloak
    # (glibc resolves *.localhost to 127.0.0.1 before DNS, breaking server-side OIDC calls).
    if ! kubectl get secret headlamp-oidc-secret -n headlamp &>/dev/null; then
        local oidc_issuer
        if [[ "$DOMAIN" == "localhost" || "$DOMAIN" == *.localhost ]]; then
            oidc_issuer="http://keycloak-keycloakx-http.keycloak.svc.cluster.local/realms/devops"
        else
            oidc_issuer="https://keycloak.${DOMAIN}/realms/devops"
        fi
        kubectl create secret generic headlamp-oidc-secret -n headlamp \
            --from-literal=clientID="headlamp" \
            --from-literal=clientSecret="placeholder" \
            --from-literal=issuerURL="${oidc_issuer}" \
            --from-literal=scopes="openid,profile,email,groups"
    fi

    local values_args=$(get_values_args "headlamp")

    helm upgrade --install headlamp headlamp/headlamp \
        --namespace headlamp \
        --version 0.41.0 \
        $values_args \
        --atomic --timeout 5m

    log_info "Headlamp installed"
}

deploy_devops() {
    add_helm_repos
    ensure_nginx_ingress
    create_devops_namespaces
    [[ "$ENV" == "local" ]] && copy_tls_secrets
    install_cert_manager
    install_external_dns
    install_data_services
    install_monitoring
    install_keycloak
    install_vault
    install_external_secrets
    install_gitlab
    install_argocd
    install_crossplane
    install_headlamp
    apply_devops_ingress
}

delete_devops() {
    log_step "Deleting DevOps platform..."

    kubectl delete -f "${BASE_DIR}/crossplane/provider-upcloud.yaml" 2>/dev/null || true
    kubectl delete -f "${BASE_DIR}/crossplane/provider-config.yaml" 2>/dev/null || true
    helm uninstall crossplane -n crossplane-system 2>/dev/null || true
    helm uninstall headlamp -n headlamp 2>/dev/null || true
    kubectl delete -f "${BASE_DIR}/devops/headlamp/rbac.yaml" 2>/dev/null || true
    helm uninstall argocd -n argocd 2>/dev/null || true
    helm uninstall external-dns -n external-dns 2>/dev/null || true
    helm uninstall gitlab -n gitlab 2>/dev/null || true
    helm uninstall prometheus -n monitoring 2>/dev/null || true
    helm uninstall loki -n monitoring 2>/dev/null || true
    helm uninstall tempo -n monitoring 2>/dev/null || true
    helm uninstall alloy -n monitoring 2>/dev/null || true
    helm uninstall vault -n vault 2>/dev/null || true
    helm uninstall keycloak -n keycloak 2>/dev/null || true
    # Clean up legacy per-service PostgreSQL (if migrating from old layout)
    kubectl delete statefulset keycloak-postgresql -n keycloak 2>/dev/null || true
    kubectl delete service keycloak-postgresql -n keycloak 2>/dev/null || true
    kubectl delete pvc keycloak-postgresql-pvc -n keycloak 2>/dev/null || true
    helm uninstall external-secrets -n external-secrets 2>/dev/null || true
    helm uninstall cert-manager -n cert-manager 2>/dev/null || true

    # Delete shared data services (local only)
    if [[ "$DATA_SERVICES_TYPE" == "local" ]]; then
        local DATA_SERVICES_DIR="${OVERLAY_DIR}/data-services"
        kubectl delete -f "${DATA_SERVICES_DIR}/minio.yaml" 2>/dev/null || true
        kubectl delete -f "${DATA_SERVICES_DIR}/valkey.yaml" 2>/dev/null || true
        kubectl delete -f "${DATA_SERVICES_DIR}/postgresql.yaml" 2>/dev/null || true
    fi

    kubectl delete -k "${OVERLAY_DIR}/devops" 2>/dev/null || true

    log_info "DevOps platform deleted"
}

status_devops() {
    log_step "DevOps Platform Status:"
    echo ""
    for ns in data-services keycloak vault gitlab argocd monitoring external-secrets cert-manager crossplane-system external-dns headlamp; do
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
    echo "  - Headlamp:   https://headlamp.${DOMAIN}"
    echo "  - Crossplane: kubectl get providers (cluster-scoped)"
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
    echo "  Bootstrap with: ./deploy.sh --env ${ENV} bootstrap"
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
                crossplane)
                    add_helm_repos && install_crossplane
                    ;;
                headlamp)
                    add_helm_repos && install_headlamp
                    ;;
                external-dns)
                    add_helm_repos && install_external_dns
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
            echo ""
            echo "Usage: $0 --env local|upcloud-dev|upcloud-prod [component] [action]"
            echo ""
            echo "Components:"
            echo "  all        - Deploy entire platform (alias for devops)"
            echo "  devops     - DevOps platform"
            echo "  data-services, keycloak, vault, monitoring, gitlab, argocd, crossplane, external-dns - Individual components"
            echo "  bootstrap  - Deploy ArgoCD app-of-apps for GitOps"
            echo ""
            echo "Actions:"
            echo "  deploy     - Deploy (default)"
            echo "  status     - Show status"
            echo "  delete     - Delete resources"
            exit 1
            ;;
    esac
}

main
