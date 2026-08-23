#!/bin/bash
set -euo pipefail

# =============================================================================
# Kubernetes Platform Deploy Script
# =============================================================================
# Deploys the DevOps platform to a local or managed-cloud environment.
#
# Usage: ./deploy.sh --env <env> [component] [action]
#
# Components: all, devops, or a single service (keycloak, vault, monitoring, ...)
# Actions:    deploy (default), status, delete
#
# Special components:
#   db-users         create managed-PostgreSQL users (run once per new database)
#   platform-secrets move platform credentials into Vault + ExternalSecrets
#   gitops           hand platform components over to ArgoCD (platform-appset)
#   bootstrap        deploy the ArgoCD app-of-apps
#   loki-auth        (re)generate the Loki ingest credentials for workload clusters
#
# Applications are managed via ArgoCD GitOps (see k8s/argocd/).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Parse --env and remaining args
parse_env_arg "$@"
# Empty-array expansion is unsafe under `set -u` on older bash.
if [[ ${#ARGS[@]} -gt 0 ]]; then set -- "${ARGS[@]}"; else set --; fi

COMPONENT="${1:-all}"
ACTION="${2:-deploy}"

if is_workload_env; then
    log_error "deploy.sh manages platform clusters. For workload clusters use:"
    log_error "  ./deploy-workload.sh --env ${ENV}"
    exit 1
fi

setup_paths
parse_config

CLOUD="$(env_cloud)"

# ─── Chart and component versions ─────────────────────────────────────
# One place to bump, mirrored by k8s/argocd/platform-appset.yaml (which ArgoCD
# reconciles after the GitOps handover) and grouped for Renovate.
CHART_CERT_MANAGER="v1.21.1"
CHART_EXTERNAL_DNS="1.21.1"
CHART_EXTERNAL_SECRETS="2.9.0"
CHART_VAULT="0.34.1"
CHART_PROMETHEUS_STACK="88.3.0"
CHART_LOKI="7.3.0"
CHART_TEMPO="1.24.4"
CHART_ALLOY="1.11.1"
CHART_ARGOCD="10.3.3"
CHART_HEADLAMP="0.44.0"
CHART_HOMEPAGE="2.1.0"
CHART_VELERO="12.1.0"
CHART_CLUSTER_AUTOSCALER="9.59.0"
CHART_FORGEJO="17.1.4"
CHART_WOODPECKER="3.7.0"
CHART_ENVOY_GATEWAY="1.9.0"
CHART_KYVERNO="3.8.2"
CHART_RELOADER="2.2.16"

# The Keycloak Operator ships as plain manifests, not a chart.
KEYCLOAK_OPERATOR_VERSION="26.7.1"
KEYCLOAK_MANIFEST_BASE="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_OPERATOR_VERSION}/kubernetes"

# Point at this environment's cluster rather than whatever context is active.
use_env_kubeconfig

# Credentials produced by tofu (managed environments).
SECRETS_FILE="${SCRIPT_ENV_DIR}/secrets.env"
MANUAL_SECRETS_FILE="${SCRIPT_ENV_DIR}/manual-secrets.env"
load_secrets() {
    if [[ -f "$SECRETS_FILE" ]]; then
        set -a; source "$SECRETS_FILE"; set +a
    fi
    if [[ -f "$MANUAL_SECRETS_FILE" ]]; then
        set -a; source "$MANUAL_SECRETS_FILE"; set +a
    fi
}
load_secrets

# =============================================================================
# Cluster prerequisites
# =============================================================================

create_devops_namespaces() {
    log_step "Creating DevOps namespaces..."
    kubectl apply -f "${BASE_DIR}/devops/namespaces/namespaces.yaml"
    log_info "Namespaces created"
}

apply_scheduling_policies() {
    log_step "Applying priority classes..."
    kubectl apply -f "${BASE_DIR}/devops/policy/priority-classes.yaml"
    log_info "Priority classes applied"
}

apply_network_policies() {
    log_step "Applying network policies..."
    kubectl apply -f "${BASE_DIR}/devops/policy/network-policies.yaml"
    log_info "Network policies applied (default-deny ingress per namespace)"
}

apply_disruption_budgets() {
    log_step "Applying pod disruption budgets..."
    kubectl apply -f "${BASE_DIR}/devops/policy/pod-disruption-budgets.yaml"
    log_info "PodDisruptionBudgets applied"
}

install_storage_class() {
    # EKS has no usable default StorageClass; every other target does.
    if [[ "$CLOUD" != "aws" ]]; then return 0; fi

    log_step "Applying gp3 default StorageClass..."
    kubectl apply -f "${BASE_DIR}/devops/storage/storageclass-aws.yaml"

    # gp2 ships as the default on older clusters; two defaults is undefined behaviour.
    if kubectl get storageclass gp2 &>/dev/null; then
        kubectl patch storageclass gp2 \
            -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
            &>/dev/null || true
    fi
    log_info "gp3 is the default StorageClass"
}

# =============================================================================
# Platform components
# =============================================================================

install_cert_manager() {
    if [[ "$ENV" == "local" ]]; then
        log_info "Skipping cert-manager (using local CA)"
        return 0
    fi

    log_step "Installing cert-manager..."

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version "$CHART_CERT_MANAGER" \
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
        local PG_FORGEJO_PASSWORD=$(openssl rand -base64 24)

        kubectl create secret generic postgresql-credentials -n data-services \
            --from-literal=postgres-password="$PG_ADMIN_PASSWORD" \
            --from-literal=keycloak-password="$PG_KEYCLOAK_PASSWORD" \
            --from-literal=forgejo-password="$PG_FORGEJO_PASSWORD"

        # Consumed by install_forgejo when there is no managed database.
        kubectl create secret generic forgejo-db-credentials -n data-services \
            --from-literal=password="$PG_FORGEJO_PASSWORD"

        # Create corresponding secrets in consuming namespaces
        kubectl create namespace keycloak 2>/dev/null || true
        kubectl create secret generic keycloak-db-secret -n keycloak \
            --from-literal=username=keycloak \
            --from-literal=password="$PG_KEYCLOAK_PASSWORD" \
            2>/dev/null || true

        kubectl create namespace forgejo 2>/dev/null || true
        kubectl create secret generic forgejo-db-secret -n forgejo \
            --from-literal=password="$PG_FORGEJO_PASSWORD" \
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
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'forgejo') THEN
    CREATE ROLE forgejo WITH LOGIN PASSWORD '${PG_FORGEJO_PASSWORD}';
  END IF;
END \$\$;
CREATE DATABASE forgejo OWNER forgejo;
EOSQL
        fi
    else
        log_info "PostgreSQL credentials already exist"
    fi

    # The StatefulSets mount these; Forgejo needs neither, but the services are
    # deployed for parity with the managed environments (and MinIO gives the local
    # environment an S3 endpoint to develop against).
    if ! kubectl get secret valkey-credentials -n data-services &>/dev/null; then
        kubectl create secret generic valkey-credentials -n data-services \
            --from-literal=password="$(openssl rand -base64 24)"
    else
        log_info "Valkey credentials already exist"
    fi

    if ! kubectl get secret minio-credentials -n data-services &>/dev/null; then
        kubectl create secret generic minio-credentials -n data-services \
            --from-literal=access-key="$(openssl rand -hex 16)" \
            --from-literal=secret-key="$(openssl rand -base64 32)"
    else
        log_info "MinIO credentials already exist"
    fi

    # Deploy PostgreSQL, Valkey, MinIO
    log_info "Deploying PostgreSQL..."
    kubectl apply -f "${DATA_SERVICES_DIR}/postgresql.yaml"
    log_info "Deploying Valkey..."
    kubectl apply -f "${DATA_SERVICES_DIR}/valkey.yaml"
    log_info "Deploying MinIO..."
    # A Job's pod template is immutable, so re-applying minio.yaml after editing the
    # bucket list fails. The job only runs `mc mb --ignore-existing`, so recreating
    # it on every deploy is both safe and the only way to stay idempotent.
    kubectl delete job minio-init-buckets -n data-services --ignore-not-found >/dev/null
    kubectl apply -f "${DATA_SERVICES_DIR}/minio.yaml"

    log_info "Waiting for data services to be ready..."
    kubectl wait --for=condition=ready pod -l app=postgresql -n data-services --timeout=120s || true
    kubectl wait --for=condition=ready pod -l app=valkey -n data-services --timeout=120s || true
    kubectl wait --for=condition=ready pod -l app=minio -n data-services --timeout=120s || true

    log_info "Shared data services installed"
}

# Managed clouds: create the K8s secrets the charts expect, from the credentials
# tofu generated. This used to print a list of kubectl commands and leave the
# operator to run them by hand, which is both error-prone and how half-configured
# clusters happen.
configure_managed_data_services() {
    log_step "Configuring managed data services..."

    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "No credentials found at ${SECRETS_FILE}"
        log_error "Run: ./sync-tofu-outputs.sh --env ${ENV}"
        exit 1
    fi

    [[ -n "${PG_HOST:-}" ]] || { log_error "PG_HOST missing from tofu outputs"; exit 1; }

    kubectl create namespace keycloak 2>/dev/null || true
    kubectl create namespace forgejo 2>/dev/null || true

    log_info "PostgreSQL: ${PG_HOST}:${PG_PORT}"

    # The Keycloak Operator reads username and password from this secret.
    kubectl create secret generic keycloak-db-secret -n keycloak \
        --from-literal=username=keycloak \
        --from-literal=password="${PG_KEYCLOAK_PASSWORD}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # Forgejo takes its database password as a config override env var.
    kubectl create secret generic forgejo-db-secret -n forgejo \
        --from-literal=password="${PG_FORGEJO_PASSWORD}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    log_info "Managed data service secrets created"
}

# Managed PostgreSQL has no Terraform resource for local users, so create them
# from a throwaway pod using the admin credentials tofu generated.
create_db_users() {
    log_step "Creating managed PostgreSQL users..."

    if [[ "$DATA_SERVICES_TYPE" != "managed" ]]; then
        log_info "Local data services create their users via the init SQL — nothing to do"
        return 0
    fi

    [[ -f "$SECRETS_FILE" ]] || { log_error "No ${SECRETS_FILE}; run sync-tofu-outputs.sh first"; exit 1; }
    [[ -n "${PG_ADMIN_PASSWORD:-}" ]] || { log_error "PG_ADMIN_PASSWORD missing from ${SECRETS_FILE}"; exit 1; }
    # Without a host psql silently dials the pod-local socket and the error that
    # comes back ("is the server running locally?") points everywhere but here.
    [[ -n "${PG_HOST:-}" ]] || { log_error "PG_HOST is empty — the synced outputs predate the database; run: ./devhub sync --env ${ENV}"; exit 1; }

    local admin_login="${PG_ADMIN_LOGIN:-pgadmin}"

    # db-users runs before the platform deploy (Keycloak and Forgejo cannot start
    # without their database users), so the namespace it borrows may not exist yet.
    kubectl create namespace data-services 2>/dev/null || true

    local sql
    sql="$(cat <<EOSQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') THEN
    CREATE ROLE keycloak WITH LOGIN PASSWORD '${PG_KEYCLOAK_PASSWORD}';
  ELSE
    ALTER ROLE keycloak WITH PASSWORD '${PG_KEYCLOAK_PASSWORD}';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'forgejo') THEN
    CREATE ROLE forgejo WITH LOGIN PASSWORD '${PG_FORGEJO_PASSWORD}';
  ELSE
    ALTER ROLE forgejo WITH PASSWORD '${PG_FORGEJO_PASSWORD}';
  END IF;
END \$\$;
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
GRANT ALL PRIVILEGES ON DATABASE forgejo TO forgejo;
EOSQL
)"

    # The pod runs inside the cluster, which is the only network with a route to
    # the private database endpoint.
    #
    # The kubelet expands $(VAR) references in a container's command and args,
    # and reduces every literal $$ to $ — which turned the SQL's `DO $$` into
    # `DO $` inside the pod. Doubling each $ makes the kubelet reconstruct the
    # string exactly (this also protects passwords that contain a dollar sign).
    local sql_arg="${sql//$/\$\$}"
    kubectl run "pg-init-$$" \
        --rm -i --restart=Never \
        --image=postgres:16 \
        --namespace=data-services \
        --env="PGPASSWORD=${PG_ADMIN_PASSWORD}" \
        --command -- psql \
            -h "${PG_HOST}" -p "${PG_PORT}" -U "${admin_login}" -d postgres \
            -v ON_ERROR_STOP=1 -c "$sql_arg"

    # PostgreSQL 15 revoked PUBLIC's CREATE on schema public, so owning a
    # database is not enough — without an explicit grant *inside each
    # database*, Keycloak's first migration dies on "permission denied for
    # schema public". Runs in its own pod because the grant must execute
    # connected to the target database, not to postgres.
    log_step "Granting schema rights inside each database..."
    kubectl run "pg-grant-$$" \
        --rm -i --restart=Never \
        --image=postgres:16 \
        --namespace=data-services \
        --env="PGPASSWORD=${PG_ADMIN_PASSWORD}" \
        --env="PGHOST=${PG_HOST}" \
        --env="PGPORT=${PG_PORT}" \
        --env="PGUSER=${admin_login}" \
        --command -- sh -ce "psql -d keycloak -v ON_ERROR_STOP=1 -c 'GRANT ALL ON SCHEMA public TO keycloak;'; psql -d forgejo -v ON_ERROR_STOP=1 -c 'GRANT ALL ON SCHEMA public TO forgejo;'"

    # Marker for quickstart's detector: nothing else this step creates is
    # observable from outside (the users live in the managed database), and the
    # secret the old detector looked for is created by a later deploy step.
    kubectl create configmap devhub-db-users-created -n data-services \
        --from-literal=createdBy=deploy.sh --dry-run=client -o yaml | kubectl apply -f -

    log_info "Database users created"
}

# Keycloak via the official Operator — the project's recommended way to run on
# Kubernetes. It owns the StatefulSet, performs database migrations on upgrade and
# exposes realms as CRDs, replacing the community keycloakx chart.
install_keycloak() {
    log_step "Installing Keycloak (operator ${KEYCLOAK_OPERATOR_VERSION})..."

    kubectl create namespace keycloak 2>/dev/null || true

    # Admin bootstrap credentials. The operator reads username/password.
    if ! kubectl get secret keycloak-admin-secret -n keycloak &>/dev/null; then
        kubectl create secret generic keycloak-admin-secret -n keycloak \
            --from-literal=username=admin \
            --from-literal=password="$(openssl rand -base64 24)"
    fi

    # All four CRDs, not just Keycloak + KeycloakRealmImport: the operator starts an
    # informer for every type it owns and exits if one is missing.
    log_info "Applying Keycloak CRDs..."
    local crd
    for crd in keycloaks keycloakrealmimports keycloakoidcclients keycloaksamlclients; do
        kubectl apply --server-side -f "${KEYCLOAK_MANIFEST_BASE}/${crd}.k8s.keycloak.org-v1.yml"
    done

    log_info "Installing the operator..."
    kubectl apply -n keycloak -f "${KEYCLOAK_MANIFEST_BASE}/kubernetes.yml"
    kubectl rollout status deploy/keycloak-operator -n keycloak --timeout=180s \
        || log_warn "Operator not ready yet — check: kubectl logs -n keycloak deploy/keycloak-operator"

    # The Keycloak instance itself.
    local dir; dir="$(render_dir)"
    template_values "${BASE_DIR}/devops/keycloak/keycloak-cr.yaml" "${dir}/keycloak-cr.yaml"
    kubectl apply -f "${dir}/keycloak-cr.yaml"

    log_info "Waiting for Keycloak to become ready (first start runs migrations)..."
    kubectl wait --for=condition=Ready keycloak/keycloak -n keycloak --timeout=600s \
        || log_warn "Keycloak not ready yet — check: kubectl describe keycloak keycloak -n keycloak"

    log_info "Keycloak installed"
}

install_vault() {
    log_step "Installing Vault..."

    kubectl create namespace vault 2>/dev/null || true

    local values_args=$(get_values_args "vault")

    # Cloud KMS auto-unseal, when tofu has provisioned the key. Without it Vault
    # needs manual unsealing after every restart, which is why unseal keys used
    # to be parked in a cluster secret.
    local autounseal_overlay="${OVERLAY_DIR}/devops/vault/vault-autounseal-values.yaml"
    if [[ -f "$autounseal_overlay" ]]; then
        local apply_autounseal=false
        case "$CLOUD" in
            aws)   [[ -n "${VAULT_KMS_KEY_ID:-}" ]]      && apply_autounseal=true ;;
            azure) [[ -n "${VAULT_KEY_VAULT_NAME:-}" ]]  && apply_autounseal=true ;;
            gcp)   [[ -n "${VAULT_KMS_KEY_RING:-}" ]]    && apply_autounseal=true ;;
        esac
        if $apply_autounseal; then
            local dir; dir="$(render_dir)"
            template_values "$autounseal_overlay" "${dir}/vault-autounseal-values.yaml"
            values_args="$values_args -f ${dir}/vault-autounseal-values.yaml"
            log_info "Vault auto-unseal (cloud KMS) enabled"
        else
            log_warn "Vault KMS variables not set — Vault will need manual unsealing"
            log_warn "Provision the key with tofu, then re-run sync-tofu-outputs.sh"
        fi
    fi

    helm upgrade --install vault hashicorp/vault \
        --namespace vault \
        --version "$CHART_VAULT" \
        $values_args \
        --atomic --timeout 5m

    # Scheduled raft snapshots (consistent backups Vault can actually restore).
    kubectl apply -f "${BASE_DIR}/devops/vault/raft-snapshot-cronjob.yaml"

    log_info "Vault installed"
}

install_external_dns() {
    if [[ "$ENV" == "local" ]]; then
        log_info "Skipping external-dns (not needed for local)"
        return 0
    fi

    # UpCloud has no external-dns provider; the overlay uses Cloudflare with a
    # hand-made token secret (preflight prints the command). Installing without
    # it would not merely degrade — the pod never starts and --atomic below
    # rolls the release back, failing the whole deploy. Skip and say why.
    if [[ "$CLOUD" == "upcloud" ]]; then
        kubectl create namespace external-dns 2>/dev/null || true
        if ! kubectl get secret external-dns-cloudflare -n external-dns &>/dev/null; then
            log_warn "Skipping external-dns: secret external-dns-cloudflare not found."
            log_warn "Create it, then re-run this component:"
            log_warn "  kubectl create secret generic external-dns-cloudflare -n external-dns \\"
            log_warn "    --from-literal=api-token=<Cloudflare token with DNS:Edit>"
            log_warn "  ./deploy.sh --env ${ENV} external-dns"
            return 0
        fi
    fi

    log_step "Installing external-dns..."

    # The Azure provider insists on /etc/kubernetes/azure.json; the chart has
    # no values key for it, so the overlay mounts this Secret. resourceGroup is
    # mandatory ("parameter resourceGroupName cannot be empty") and names where
    # the DNS *zone* lives — found the same way preflight finds it.
    if [[ "$CLOUD" == "azure" ]]; then
        local dns_rg
        dns_rg="$(az network dns zone list --query "[?name=='${DOMAIN}'].resourceGroup" -o tsv 2>/dev/null | head -1)"
        if [[ -z "$dns_rg" ]]; then
            log_error "No Azure DNS zone found for ${DOMAIN} — external-dns needs the zone's resource group."
            log_error "Create the zone (az network dns zone create -n ${DOMAIN} -g <rg>), then re-run:"
            log_error "  ./deploy.sh --env ${ENV} external-dns"
            return 1
        fi
        kubectl create namespace external-dns 2>/dev/null || true
        kubectl create secret generic external-dns-azure-config -n external-dns \
            --from-literal=azure.json="{\"tenantId\": \"${ENTRA_TENANT_ID}\", \"subscriptionId\": \"${AZURE_SUBSCRIPTION_ID}\", \"resourceGroup\": \"${dns_rg}\", \"useWorkloadIdentityExtension\": true}" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    local values_args=$(get_values_args "external-dns")

    helm upgrade --install external-dns external-dns/external-dns \
        --namespace external-dns \
        --create-namespace \
        --version "$CHART_EXTERNAL_DNS" \
        $values_args \
        --atomic --timeout 5m

    log_info "external-dns installed"
}

install_external_secrets() {
    log_step "Installing External Secrets..."

    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets \
        --create-namespace \
        --version "$CHART_EXTERNAL_SECRETS" \
        -f "${BASE_DIR}/devops/external-secrets/values.yaml" \
        --atomic --timeout 10m

    log_info "External Secrets installed"
}

# Generate the Loki ingest credentials used by workload clusters, and expose the
# push endpoint. Basic auth via nginx, because the endpoint is public.
setup_loki_auth() {
    log_step "Configuring Loki ingest authentication..."

    kubectl create namespace monitoring 2>/dev/null || true

    if ! kubectl get secret loki-gateway-auth -n monitoring &>/dev/null; then
        local password
        password="$(openssl rand -base64 24 | tr -d '/+=')"

        # Envoy Gateway's BasicAuth reads an htpasswd file from the .htpasswd key.
        local htpasswd
        htpasswd="workload:$(openssl passwd -apr1 "$password")"

        kubectl create secret generic loki-gateway-auth -n monitoring \
            --from-literal=.htpasswd="$htpasswd"

        # Store the plaintext for register-workload-cluster.sh to distribute.
        kubectl create secret generic loki-ingest-credentials -n monitoring \
            --from-literal=username=workload \
            --from-literal=password="$password"

        log_info "Generated Loki ingest credentials (user: workload)"
    else
        log_info "Loki ingest credentials already exist"
    fi

    if [[ "$ENV" != "local" ]]; then
        # The route itself lives in httproutes.yaml; this attaches basic auth to it.
        kubectl apply -f "${BASE_DIR}/devops/monitoring/loki-securitypolicy.yaml"
        log_info "Loki push endpoint published at https://loki.${DOMAIN}/loki/api/v1/push (basic auth)"
    fi
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

    # Alertmanager mounts this; an empty webhook keeps the config valid while
    # alerts remain visible in the Alertmanager UI.
    if ! kubectl get secret alertmanager-slack -n monitoring &>/dev/null; then
        kubectl create secret generic alertmanager-slack -n monitoring \
            --from-literal=webhook-url=""
        log_warn "Alertmanager Slack webhook is empty — alerts fire but are not delivered"
        log_warn "Set one: vault kv put secret/platform/alertmanager webhook-url=https://hooks.slack.com/..."
    fi

    # Prometheus stack uses monitoring overlay
    local base_values="${BASE_DIR}/devops/monitoring/prometheus-stack-values.yaml"
    local overlay_values="${OVERLAY_DIR}/devops/monitoring/values.yaml"
    local dir; dir="$(render_dir)"

    local prom_args="-f $base_values"
    if [[ -f "$overlay_values" ]]; then
        template_values "$overlay_values" "${dir}/monitoring-overlay-values.yaml"
        prom_args="$prom_args -f ${dir}/monitoring-overlay-values.yaml"
    fi

    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --version "$CHART_PROMETHEUS_STACK" \
        $prom_args \
        --atomic --timeout 10m

    # Platform-specific alert rules (sealed Vault, stuck syncs, failed backups)
    kubectl apply -f "${BASE_DIR}/devops/monitoring/platform-alerts.yaml"

    # Loki: object storage overlay when the cloud identity exists, filesystem otherwise
    local loki_args="-f ${BASE_DIR}/devops/monitoring/loki-values.yaml"
    local loki_overlay="${OVERLAY_DIR}/devops/monitoring/loki-values.yaml"
    if [[ -f "$loki_overlay" ]]; then
        local apply_loki_overlay=false
        case "$CLOUD" in
            aws)   [[ -n "${LOKI_IRSA_ROLE_ARN:-}" ]]     && apply_loki_overlay=true ;;
            azure) [[ -n "${LOKI_IDENTITY_CLIENT_ID:-}" ]] && apply_loki_overlay=true ;;
            gcp)   [[ -n "${LOKI_GSA_EMAIL:-}" ]]          && apply_loki_overlay=true ;;
            upcloud) [[ -n "${LOKI_S3_ACCESS_KEY_ID:-}" ]] && apply_loki_overlay=true ;;
        esac
        if $apply_loki_overlay; then
            # UpCloud has no workload identity: Loki's S3 client falls back to
            # the standard AWS env-var credential chain, fed from this Secret
            # via the overlay's extraEnvFrom. Keys stay out of values files.
            if [[ "$CLOUD" == "upcloud" ]]; then
                kubectl create secret generic loki-objstore-credentials -n monitoring \
                    --from-literal=AWS_ACCESS_KEY_ID="${LOKI_S3_ACCESS_KEY_ID}" \
                    --from-literal=AWS_SECRET_ACCESS_KEY="${LOKI_S3_SECRET_ACCESS_KEY}" \
                    --dry-run=client -o yaml | kubectl apply -f -
            fi
            template_values "$loki_overlay" "${dir}/loki-overlay-values.yaml"
            loki_args="$loki_args -f ${dir}/loki-overlay-values.yaml"
            log_info "Loki cloud object storage enabled (${LOKI_BUCKET:-${LOKI_CONTAINER:-}})"
        else
            log_warn "Loki object-storage identity not set — using a local PVC (logs lost on pod recycle)"
        fi
    fi

    helm upgrade --install loki grafana/loki \
        --namespace monitoring \
        --version "$CHART_LOKI" \
        $loki_args \
        --atomic --timeout 10m

    helm upgrade --install tempo grafana/tempo \
        --namespace monitoring \
        --version "$CHART_TEMPO" \
        -f "${BASE_DIR}/devops/monitoring/tempo-values.yaml" \
        --atomic --timeout 5m

    helm upgrade --install alloy grafana/alloy \
        --namespace monitoring \
        --version "$CHART_ALLOY" \
        -f "${BASE_DIR}/devops/monitoring/alloy-values.yaml" \
        --atomic --timeout 5m

    setup_loki_auth

    # Remove legacy promtail release if it still exists (replaced by Alloy)
    if helm status promtail -n monitoring &>/dev/null; then
        log_info "Removing legacy promtail release (replaced by Alloy)..."
        helm uninstall promtail -n monitoring
    fi

    log_info "Monitoring stack installed"
}

install_velero() {
    if [[ "$ENV" == "local" ]]; then
        log_info "Skipping Velero (no cloud backup target for local)"
        return 0
    fi

    local have_target=false
    case "$CLOUD" in
        aws)   [[ -n "${VELERO_BUCKET:-}" ]]    && have_target=true ;;
        gcp)   [[ -n "${VELERO_BUCKET:-}" ]]    && have_target=true ;;
        azure) [[ -n "${VELERO_CONTAINER:-}" ]] && have_target=true ;;
        upcloud) [[ -n "${VELERO_BUCKET:-}" && -n "${VELERO_S3_ACCESS_KEY_ID:-}" ]] && have_target=true ;;
    esac

    if ! $have_target; then
        log_warn "Skipping Velero: no backup bucket in the tofu outputs for ${CLOUD}"
        log_warn "Apply the platform tofu module, then re-run sync-tofu-outputs.sh"
        return 0
    fi

    log_step "Installing Velero (cluster backups)..."

    kubectl create namespace velero 2>/dev/null || true

    # UpCloud has no workload identity: the chart mounts this Secret as the
    # AWS-style credentials file (credentials.existingSecret in the overlay).
    if [[ "$CLOUD" == "upcloud" ]]; then
        kubectl create secret generic velero-objstore-credentials -n velero \
            --from-literal=cloud="[default]
aws_access_key_id=${VELERO_S3_ACCESS_KEY_ID}
aws_secret_access_key=${VELERO_S3_SECRET_ACCESS_KEY}" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    local values_args=$(get_values_args "velero")

    helm upgrade --install velero vmware-tanzu/velero \
        --namespace velero \
        --version "$CHART_VELERO" \
        $values_args \
        --atomic --timeout 10m

    log_info "Velero installed — daily full backups at 02:00, platform state hourly"
}

install_cluster_autoscaler() {
    # AWS is the only target where the autoscaler is a separate component; AKS and
    # GKE run theirs inside the managed control plane.
    if [[ "$CLOUD" != "aws" ]]; then return 0; fi
    if [[ -z "${CLUSTER_AUTOSCALER_IRSA_ROLE_ARN:-}" ]]; then
        log_warn "Skipping cluster-autoscaler: CLUSTER_AUTOSCALER_IRSA_ROLE_ARN not set"
        return 0
    fi

    log_step "Installing cluster-autoscaler..."

    helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
        --namespace kube-system \
        --version "$CHART_CLUSTER_AUTOSCALER" \
        --set autoDiscovery.clusterName="${CLUSTER_NAME}" \
        --set awsRegion="${AWS_REGION}" \
        --set rbac.serviceAccount.name=cluster-autoscaler \
        --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${CLUSTER_AUTOSCALER_IRSA_ROLE_ARN}" \
        --set extraArgs.balance-similar-node-groups=true \
        --set extraArgs.skip-nodes-with-local-storage=false \
        --set priorityClassName=platform-standard \
        --atomic --timeout 5m

    log_info "cluster-autoscaler installed"
}

# Forgejo — git hosting, issues, packages and the container registry.
install_forgejo() {
    log_step "Installing Forgejo..."

    kubectl create namespace forgejo 2>/dev/null || true

    # Admin account for first login (SSO users arrive via Keycloak afterwards).
    if ! kubectl get secret forgejo-admin-secret -n forgejo &>/dev/null; then
        kubectl create secret generic forgejo-admin-secret -n forgejo \
            --from-literal=username=devhub-admin \
            --from-literal=password="$(openssl rand -base64 24)" \
            --from-literal=email="${ACME_EMAIL:-admin@${DOMAIN}}"
    fi

    # Database password, injected as a Forgejo config override.
    if ! kubectl get secret forgejo-db-secret -n forgejo &>/dev/null; then
        local pw="${PG_FORGEJO_PASSWORD:-}"
        if [[ -z "$pw" ]]; then
            pw="$(kubectl get secret forgejo-db-credentials -n data-services \
                  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
        fi
        [[ -n "$pw" ]] || { log_error "No Forgejo database password available"; exit 1; }
        kubectl create secret generic forgejo-db-secret -n forgejo \
            --from-literal=password="$pw"
    fi

    # No OIDC secret is needed at install time: setup-keycloak.sh registers the
    # login source through Forgejo's admin CLI once the realm exists.

    local values_args=$(get_values_args "forgejo")

    helm upgrade --install forgejo oci://code.forgejo.org/forgejo-helm/forgejo \
        --namespace forgejo \
        --version "$CHART_FORGEJO" \
        $values_args \
        --atomic --timeout 10m

    log_info "Forgejo installed — https://git.${DOMAIN}"
}

# Woodpecker CI — pipelines for Forgejo repositories, each step an unprivileged pod.
install_woodpecker() {
    log_step "Installing Woodpecker CI..."

    kubectl create namespace woodpecker 2>/dev/null || true
    kubectl create namespace woodpecker-ci 2>/dev/null || true

    # Shared secret between server and agents.
    # The name is the chart's: its agent StatefulSet mounts
    # woodpecker-default-agent-secret unconditionally.
    if ! kubectl get secret woodpecker-default-agent-secret -n woodpecker &>/dev/null; then
        local agent_secret; agent_secret="$(openssl rand -hex 32)"
        kubectl create secret generic woodpecker-default-agent-secret -n woodpecker \
            --from-literal=WOODPECKER_AGENT_SECRET="$agent_secret"
        # The server needs the same value plus the Forgejo OAuth application.
        kubectl create secret generic woodpecker-server-secret -n woodpecker \
            --from-literal=WOODPECKER_AGENT_SECRET="$agent_secret" \
            --from-literal=WOODPECKER_GITEA_CLIENT=placeholder \
            --from-literal=WOODPECKER_GITEA_SECRET=placeholder
        log_warn "Woodpecker's Forgejo OAuth application is a placeholder."
        log_warn "Create it in Forgejo (Settings → Applications) and update:"
        log_warn "  kubectl create secret generic woodpecker-server-secret -n woodpecker ..."
    fi

    local values_args=$(get_values_args "woodpecker")

    helm upgrade --install woodpecker woodpecker/woodpecker \
        --namespace woodpecker \
        --version "$CHART_WOODPECKER" \
        $values_args \
        --atomic --timeout 10m

    log_info "Woodpecker installed — https://ci.${DOMAIN}"
}

# Woodpecker signs users in through Forgejo, so it needs an OAuth2 application
# registered there. Forgejo's API can create one; this replaces the placeholder
# credentials install_woodpecker seeded.
configure_woodpecker_oauth() {
    log_step "Registering Woodpecker as an OAuth application in Forgejo..."

    local pod
    pod="$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
    if [[ -z "$pod" ]]; then
        log_warn "Forgejo is not running yet — run this later:"
        log_warn "  ./deploy.sh --env ${ENV} woodpecker-oauth"
        return 0
    fi

    # A short-lived admin token, used only for the two API calls below.
    local admin_user token
    admin_user="$(kubectl get secret forgejo-admin-secret -n forgejo \
        -o jsonpath='{.data.username}' | base64 -d)"
    token="$(kubectl exec -n forgejo "$pod" -- forgejo admin user generate-access-token \
        --username "$admin_user" --token-name "woodpecker-setup-$(date +%s)" \
        --scopes write:user --raw 2>/dev/null | tr -d '\r' | tail -1)"

    if [[ -z "$token" ]]; then
        log_warn "Could not mint a Forgejo admin token — register the application by hand:"
        log_warn "  Forgejo → Settings → Applications → Create OAuth2 application"
        log_warn "  Redirect URI: https://ci.${DOMAIN}/authorize"
        return 0
    fi

    local response
    response="$(kubectl exec -n forgejo "$pod" -- curl -fsS \
        -X POST "http://localhost:3000/api/v1/user/applications/oauth2" \
        -H "Authorization: token ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"Woodpecker CI\",\"redirect_uris\":[\"https://ci.${DOMAIN}/authorize\"],\"confidential_client\":true}" \
        2>/dev/null || echo "")"

    local client_id client_secret
    client_id="$(echo "$response" | jq -r '.client_id // empty' 2>/dev/null)"
    client_secret="$(echo "$response" | jq -r '.client_secret // empty' 2>/dev/null)"

    if [[ -z "$client_id" || -z "$client_secret" ]]; then
        log_warn "Forgejo did not return OAuth credentials; register the application by hand."
        return 0
    fi

    local agent_secret
    agent_secret="$(kubectl get secret woodpecker-default-agent-secret -n woodpecker \
        -o jsonpath='{.data.WOODPECKER_AGENT_SECRET}' | base64 -d)"

    kubectl create secret generic woodpecker-server-secret -n woodpecker \
        --from-literal=WOODPECKER_AGENT_SECRET="$agent_secret" \
        --from-literal=WOODPECKER_GITEA_CLIENT="$client_id" \
        --from-literal=WOODPECKER_GITEA_SECRET="$client_secret" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    kubectl rollout restart statefulset/woodpecker-server -n woodpecker >/dev/null 2>&1 || true
    log_info "Woodpecker OAuth application registered"
}

install_argocd() {
    log_step "Installing ArgoCD..."

    kubectl create namespace argocd 2>/dev/null || true

    local values_args=$(get_values_args "argocd")

    # On the local environment ArgoCD's OIDC discovery call targets
    # keycloak.localhost, and glibc resolves *.localhost to 127.0.0.1 before DNS.
    # A hostAlias pointing at the Envoy data-plane service makes the call land on
    # the gateway instead.
    #
    # Note what this cannot fix: git.${DOMAIN}. glibc applies the *.localhost rule
    # inside getaddrinfo, ahead of /etc/hosts, so curl and git ignore the alias
    # even though `getent hosts` honours it — a repo-server clone of
    # https://git.localhost fails with "could not connect" against its own
    # loopback. The GitOps repository is therefore addressed by Forgejo's Service
    # name instead; see GITOPS_REPO_URL_INTERNAL in lib/common.sh.
    local extra_args=""
    if [[ "$ENV" == "local" ]]; then
        local gw_ip
        gw_ip="$(kubectl get svc -n envoy-gateway-system \
            -l gateway.envoyproxy.io/owning-gateway-name=devhub \
            -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || true)"
        if [[ -n "$gw_ip" ]]; then
            extra_args="--set global.hostAliases[0].ip=${gw_ip} --set global.hostAliases[0].hostnames[0]=keycloak.${DOMAIN}"
            log_info "ArgoCD hostAlias: keycloak.${DOMAIN} -> ${gw_ip}"
        else
            log_warn "Envoy data-plane service not found — ArgoCD SSO may fail to discover Keycloak"
        fi
    fi

    # A local CA with a real domain (rather than *.localhost) does reach Forgejo
    # over HTTPS, and then the clone fails verification unless ArgoCD holds the
    # CA. The chart takes a map of server name → PEM; every dot in the key has to
    # be escaped for --set-file.
    if [[ "$TLS_TYPE" == "local-ca" && -f "${CERTS_DIR}/ca/ca.crt" && "$GITOPS_REPO_URL_INTERNAL" == https://* ]]; then
        local git_host_key="git.${DOMAIN}"
        git_host_key="${git_host_key//./\\.}"
        extra_args="${extra_args} --set-file configs.tls.certificates.${git_host_key}=${CERTS_DIR}/ca/ca.crt"
        log_info "ArgoCD trusts the local CA for git.${DOMAIN}"
    fi

    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        --version "$CHART_ARGOCD" \
        $values_args $extra_args \
        --atomic --timeout 5m

    log_info "ArgoCD installed"
}

install_headlamp() {
    log_step "Installing Headlamp..."

    kubectl create namespace headlamp 2>/dev/null || true

    if [[ "$ENV" == "local" ]] && ! kubectl get secret local-tls-secret -n headlamp &>/dev/null; then
        kubectl create secret tls local-tls-secret -n headlamp \
            --cert="${CERTS_DIR}/domains/local-dev.crt" \
            --key="${CERTS_DIR}/domains/local-dev.key"
    fi

    kubectl apply -f "${BASE_DIR}/devops/headlamp/rbac.yaml"

    # Placeholder so the SecurityPolicy resolves before Keycloak SSO is set up;
    # setup-keycloak.sh replaces it with the real client secret. Envoy Gateway
    # requires the key to be called "client-secret".
    if ! kubectl get secret headlamp-oidc-secret -n headlamp &>/dev/null; then
        kubectl create secret generic headlamp-oidc-secret -n headlamp \
            --from-literal=client-secret="placeholder"
    fi

    # Long-lived token for the read-only ServiceAccount — what users paste at
    # Headlamp's token screen. Access control happens at the gateway (Keycloak
    # SSO via the SecurityPolicy); this token only ever grants headlamp-view.
    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-view-token
  namespace: headlamp
  annotations:
    kubernetes.io/service-account.name: headlamp
type: kubernetes.io/service-account-token
EOF

    local values_args=$(get_values_args "headlamp")

    helm upgrade --install headlamp headlamp/headlamp \
        --namespace headlamp \
        --version "$CHART_HEADLAMP" \
        $values_args \
        --atomic --timeout 5m

    # Applied after the chart so the HTTPRoute's backend resolves.
    local dir
    dir="$(render_dir)"
    template_values "${BASE_DIR}/devops/headlamp/oidc-securitypolicy.yaml" \
        "${dir}/headlamp-oidc-securitypolicy.yaml"
    kubectl apply -f "${dir}/headlamp-oidc-securitypolicy.yaml"

    log_info "Headlamp installed — sign in via SSO, then paste the token from:"
    log_info "  ./deploy.sh --env ${ENV} headlamp-token"
}

# Print the read-only token users paste at Headlamp's token screen.
print_headlamp_token() {
    local token
    token="$(kubectl get secret headlamp-view-token -n headlamp \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)"
    if [[ -z "$token" ]]; then
        log_error "No headlamp-view-token yet — run: ./deploy.sh --env ${ENV} headlamp"
        exit 1
    fi
    echo "$token"
}

install_homepage() {
    log_step "Installing Homepage..."

    kubectl create namespace homepage 2>/dev/null || true

    # Placeholder so the SecurityPolicy resolves before Keycloak SSO is set up;
    # setup-keycloak.sh replaces it with the real client secret. Envoy Gateway
    # requires the key to be called "client-secret".
    if ! kubectl get secret homepage-oidc-secret -n homepage &>/dev/null; then
        kubectl create secret generic homepage-oidc-secret -n homepage \
            --from-literal=client-secret="placeholder"
    fi

    local values_args=$(get_values_args "homepage")

    helm upgrade --install homepage jameswynn/homepage \
        --namespace homepage \
        --version "$CHART_HOMEPAGE" \
        $values_args \
        --atomic --timeout 5m

    # The SecurityPolicy targets the HTTPRoute, so it is applied here rather than
    # with the routes: without the Service behind it the route does not resolve
    # and the policy has nothing to attach to.
    local dir
    dir="$(render_dir)"
    template_values "${BASE_DIR}/devops/homepage/oidc-securitypolicy.yaml" \
        "${dir}/homepage-oidc-securitypolicy.yaml"
    kubectl apply -f "${dir}/homepage-oidc-securitypolicy.yaml"

    log_info "Homepage installed"
}

# Portal — the developer wizard (see k8s/base/devops/portal/README.md).
# Raw manifests + a kustomize configMapGenerator rather than a chart: the app
# is a dependency-free Node file served from a ConfigMap on a stock image, so
# it installs before the platform's own registry and CI exist. After the
# GitOps handover, k8s/argocd/apps/portal.yaml makes ArgoCD own it.

# Mint the Forgejo token the portal calls the API with. Scoped to what the
# wizard does: create repos in the devhub org, read templates, open issues.
ensure_portal_forgejo_token() {
    kubectl create namespace portal 2>/dev/null || true

    local existing
    existing="$(kubectl get secret portal-forgejo-token -n portal \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    if [[ -n "$existing" && "$existing" != "placeholder" ]]; then
        log_info "Portal Forgejo token already exists"
        return 0
    fi

    local pod
    pod="$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
    if [[ -z "$pod" ]]; then
        log_warn "Forgejo is not running — seeding a placeholder token. Later, run:"
        log_warn "  ./deploy.sh --env ${ENV} portal-token"
        kubectl create secret generic portal-forgejo-token -n portal \
            --from-literal=token=placeholder \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        return 0
    fi

    local admin_user token
    admin_user="$(kubectl get secret forgejo-admin-secret -n forgejo \
        -o jsonpath='{.data.username}' | base64 -d)"
    token="$(kubectl exec -n forgejo "$pod" -- forgejo admin user generate-access-token \
        --username "$admin_user" --token-name "portal-$(date +%s)" \
        --scopes write:organization,write:repository,write:issue --raw 2>/dev/null \
        | tr -d '\r' | tail -1)"
    if [[ -z "$token" ]]; then
        log_warn "Could not mint a Forgejo token for the portal — re-run: ./deploy.sh --env ${ENV} portal-token"
        return 0
    fi

    kubectl create secret generic portal-forgejo-token -n portal \
        --from-literal=token="$token" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl rollout restart deployment/portal -n portal >/dev/null 2>&1 || true
    log_info "Portal Forgejo token created"
}

# Publish k8s/templates/app-template into Forgejo as devhub-templates/app-template.
#
# Its own org, never devhub: forgejo-appset deploys every devhub-org repo that
# has a k8s/ directory, and a template must not itself land on a workload
# cluster.
#
# A force-push of a fresh single-commit tree, so re-running after editing the
# template republishes it — the Forgejo copy is exactly this directory, always.
# Anyone preferring to evolve the template in Forgejo directly (the portal reads
# HEAD) just stops re-running this. History is not worth keeping here: the
# template's history lives in this repository.
publish_app_templates() {
    log_step "Publishing the app template to Forgejo..."

    local pod
    pod="$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
    if [[ -z "$pod" ]]; then
        log_warn "Forgejo is not running — publish later with: ./deploy.sh --env ${ENV} portal-templates"
        return 0
    fi

    local admin_user token
    admin_user="$(kubectl get secret forgejo-admin-secret -n forgejo \
        -o jsonpath='{.data.username}' | base64 -d)"
    token="$(kubectl exec -n forgejo "$pod" -- forgejo admin user generate-access-token \
        --username "$admin_user" --token-name "portal-templates-$(date +%s)" \
        --scopes write:organization,write:repository --raw 2>/dev/null | tr -d '\r' | tail -1)"
    if [[ -z "$token" ]]; then
        log_warn "Could not mint a Forgejo admin token — publish later with: ./deploy.sh --env ${ENV} portal-templates"
        return 0
    fi

    local api="http://localhost:3000/api/v1"
    fapi() { # method path (body on stdin)
        kubectl exec -i -n forgejo "$pod" -- curl -fsS -X "$1" "${api}$2" \
            -H "Authorization: token ${token}" -H "Content-Type: application/json" \
            --data-binary @- 2>/dev/null
    }
    fget() {
        kubectl exec -n forgejo "$pod" -- curl -fsS "${api}$1" \
            -H "Authorization: token ${token}" 2>/dev/null || true
    }

    # Both orgs: devhub-templates for the template, devhub for the apps the
    # portal will create into it (usually the gitops repo made it already).
    local org
    for org in devhub devhub-templates; do
        if [[ -z "$(fget "/orgs/${org}" | jq -r '.id // empty')" ]]; then
            echo "{\"username\":\"${org}\"}" | fapi POST /orgs >/dev/null \
                && log_info "Created Forgejo organisation: ${org}" \
                || log_warn "Could not create Forgejo organisation ${org}"
        fi
    done

    # Every directory under k8s/templates/ is a repo in devhub-templates: the
    # scaffolds the portal copies from, and the devhub-app chart their
    # values.yaml renders through (the chart-based ApplicationSet clones it).
    local -a git_env=()
    if [[ "$TLS_TYPE" == "local-ca" && -f "${CERTS_DIR}/ca/ca.crt" ]]; then
        git_env=(env "GIT_SSL_CAINFO=${CERTS_DIR}/ca/ca.crt")
    fi

    local dir name descr staging push_url
    for dir in "${K8S_DIR}/templates"/*/; do
        name="$(basename "$dir")"
        case "$name" in
            app-template)     descr="Scaffold used by the portal wizard" ;;
            devhub-app-chart) descr="Opinionated chart rendering every app's k8s/values.yaml" ;;
            *)                descr="Published from devhub k8s/templates/${name}" ;;
        esac

        if [[ -z "$(fget "/repos/devhub-templates/${name}" | jq -r '.id // empty')" ]]; then
            echo "{\"name\":\"${name}\",\"description\":\"${descr}\",\"private\":false,\"auto_init\":false,\"default_branch\":\"main\"}" \
                | fapi POST /orgs/devhub-templates/repos >/dev/null \
                || { log_warn "Could not create devhub-templates/${name}"; continue; }
        fi

        # Fresh single-commit tree, force-pushed over the public URL — same
        # reachability assumption (and same local-CA handling) as setup-gitops-repo.
        staging="$(mktemp -d "${TMPDIR:-/tmp}/devhub-template.XXXXXX")"
        cp -r "${dir}." "$staging/"
        git -C "$staging" init -q -b main
        git -C "$staging" -c user.name=devhub -c user.email="devhub@${DOMAIN}" add -A
        git -C "$staging" -c user.name=devhub -c user.email="devhub@${DOMAIN}" \
            commit -q -m "Publish ${name} from devhub"

        push_url="https://${admin_user}:${token}@git.${DOMAIN}/devhub-templates/${name}.git"
        if "${git_env[@]+"${git_env[@]}"}" git -C "$staging" push -q --force "$push_url" main; then
            log_info "Published devhub-templates/${name} (re-run this command to republish)"
        else
            log_warn "Push failed for ${name}. Is git.${DOMAIN} reachable from this machine?"
            log_warn "Retry with: ./deploy.sh --env ${ENV} portal-templates"
        fi
        rm -rf "$staging"
    done
}

# Registry credentials for CI as Woodpecker *organisation* secrets: every repo
# in the devhub org inherits registry_user/registry_token, so a scaffolded
# pipeline can push to the registry with no per-repo secret setup.
#
# Woodpecker only mints user API tokens in its UI (there is no CLI/exec path),
# so that one paste is the single manual step:
#   WOODPECKER_TOKEN=<token from https://ci.<domain>/user> \
#     ./deploy.sh --env <env> ci-secrets
# The token is kept in portal-forgejo-token's sibling secret so the portal can
# also activate repositories at scaffold time.
configure_woodpecker_ci_secrets() {
    log_step "Configuring Woodpecker org-level registry secrets..."

    # Token: the environment wins; otherwise reuse the stored secret.
    local wp_token="${WOODPECKER_TOKEN:-}"
    if [[ -z "$wp_token" ]]; then
        wp_token="$(kubectl get secret portal-woodpecker-token -n portal \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    fi
    if [[ -z "$wp_token" || "$wp_token" == "placeholder" ]]; then
        log_error "No Woodpecker API token. Create one at https://ci.${DOMAIN}/user, then:"
        log_error "  WOODPECKER_TOKEN=<token> ./deploy.sh --env ${ENV} ci-secrets"
        exit 1
    fi

    # Store it for the portal (repo activation at scaffold time).
    kubectl create namespace portal 2>/dev/null || true
    kubectl create secret generic portal-woodpecker-token -n portal \
        --from-literal=token="$wp_token" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl rollout restart deployment/portal -n portal >/dev/null 2>&1 || true

    # A Forgejo token that can push packages — the credential CI publishes with.
    local pod
    pod="$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
    [[ -n "$pod" ]] || { log_error "Forgejo is not running"; exit 1; }
    local admin_user registry_token
    admin_user="$(kubectl get secret forgejo-admin-secret -n forgejo \
        -o jsonpath='{.data.username}' | base64 -d)"
    registry_token="$(kubectl exec -n forgejo "$pod" -- forgejo admin user generate-access-token \
        --username "$admin_user" --token-name "registry-ci-$(date +%s)" \
        --scopes write:package,write:repository --raw 2>/dev/null | tr -d '\r' | tail -1)"
    [[ -n "$registry_token" ]] || { log_error "Could not mint a Forgejo registry token"; exit 1; }

    # Woodpecker API over the public URL — the same reachability assumption as
    # every other from-this-machine call; trust the local CA when there is one.
    local -a curl_ca=()
    [[ "$TLS_TYPE" == "local-ca" && -f "${CERTS_DIR}/ca/ca.crt" ]] \
        && curl_ca=(--cacert "${CERTS_DIR}/ca/ca.crt")
    wpapi() { # method path [json-body]
        curl -fsS "${curl_ca[@]+"${curl_ca[@]}"}" -X "$1" "https://ci.${DOMAIN}$2" \
            -H "Authorization: Bearer ${wp_token}" -H "Content-Type: application/json" \
            ${3:+-d "$3"} 2>/dev/null
    }

    local org_id
    org_id="$(wpapi GET "/api/orgs/lookup/devhub" | jq -r '.id // empty')"
    if [[ -z "$org_id" ]]; then
        log_error "Woodpecker does not know the devhub org yet."
        log_error "Sign in to https://ci.${DOMAIN} once (that syncs orgs from Forgejo) and re-run."
        exit 1
    fi

    # events: push only — a pull request runs code from anyone who can open
    # one, and must not be able to read the registry-write credential. PR
    # builds still build; they just cannot push (which they never do anyway).
    local name value body
    for name in registry_user registry_token; do
        [[ "$name" == "registry_user" ]] && value="$admin_user" || value="$registry_token"
        body="$(jq -n --arg n "$name" --arg v "$value" \
            '{name: $n, value: $v, events: ["push"]}')"
        if ! wpapi POST "/api/orgs/${org_id}/secrets" "$body" >/dev/null; then
            wpapi PATCH "/api/orgs/${org_id}/secrets/${name}" "$body" >/dev/null \
                || { log_error "Could not create or update org secret ${name}"; exit 1; }
        fi
    done

    log_info "Woodpecker org secrets set: registry_user, registry_token (devhub org, push events)"
    log_info "The portal will now also auto-activate scaffolded repositories in Woodpecker."
}

install_portal() {
    log_step "Installing Portal..."

    kubectl create namespace portal 2>/dev/null || true

    # Placeholder so the SecurityPolicy resolves before Keycloak SSO is set up;
    # setup-keycloak.sh replaces it. Envoy Gateway requires the key name.
    if ! kubectl get secret portal-oidc-secret -n portal &>/dev/null; then
        kubectl create secret generic portal-oidc-secret -n portal \
            --from-literal=client-secret="placeholder"
    fi

    ensure_portal_forgejo_token
    publish_app_templates

    # kubectl -k renders the kustomization (the app ConfigMap comes from a
    # configMapGenerator), so template the copy, not the source.
    local dir; dir="$(render_dir)"
    rm -rf "${dir}/portal" && mkdir -p "${dir}/portal"
    cp "${BASE_DIR}/devops/portal/"* "${dir}/portal/"
    local f
    for f in "${dir}/portal/"*.yaml; do
        template_values "$f" "${f}.rendered"
        mv "${f}.rendered" "$f"
    done
    kubectl apply -k "${dir}/portal"

    log_info "Portal installed — https://portal.${DOMAIN}"
}

# =============================================================================
# GitOps handover
# =============================================================================

bootstrap_argocd_apps() {
    log_step "Bootstrapping ArgoCD app-of-apps..."

    if [[ -z "${GITOPS_REPO_URL:-}" ]]; then
        log_error "gitops.repoUrl is not set in ${OVERLAY_DIR}/config.yaml"
        exit 1
    fi

    local dir; dir="$(render_dir)"

    for f in "${ARGOCD_DIR}"/projects/*.yaml; do
        [[ -f "$f" ]] && kubectl apply -f "$f"
    done

    template_values "${ARGOCD_DIR}/apps/app-of-apps.yaml" "${dir}/app-of-apps.yaml"
    kubectl apply -f "${dir}/app-of-apps.yaml"

    log_info "ArgoCD app-of-apps deployed (repo: ${GITOPS_REPO_URL})"
}

# Hand the non-bootstrap platform components over to ArgoCD. From here on their
# desired state is this repository, and drift is corrected automatically.
# ArgoCD credentials for the developer-app repositories. Forgejo requires
# sign-in for every view (REQUIRE_SIGNIN_VIEW), so ArgoCD cannot clone app
# repos or the devhub-app chart anonymously: register org-prefix repo-creds
# backed by a freshly minted read-only token. Idempotent — re-running replaces
# the token. Covers:
#   https://git.<domain>/devhub                     the app repos (both appsets)
#   http://forgejo-http...:3000/devhub-templates    the devhub-app chart source
ensure_argocd_repo_creds() {
    log_step "Registering ArgoCD credentials for app repositories..."

    local pod admin_user token
    pod="$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
    if [[ -z "$pod" ]]; then
        log_warn "Forgejo is not running — register later with: ./deploy.sh --env ${ENV} app-repo-creds"
        return 0
    fi
    admin_user="$(kubectl get secret forgejo-admin-secret -n forgejo \
        -o jsonpath='{.data.username}' | base64 -d)"
    token="$(kubectl exec -n forgejo "$pod" -- forgejo admin user generate-access-token \
        --username "$admin_user" --token-name "argocd-apps-$(date +%s)" \
        --scopes read:organization,read:repository --raw 2>/dev/null | tr -d '\r' | tail -1)"
    if [[ -z "$token" ]]; then
        log_warn "Could not mint a Forgejo token — register later with: ./deploy.sh --env ${ENV} app-repo-creds"
        return 0
    fi

    local name url
    for name in apps templates; do
        case "$name" in
            apps)      url="https://git.${DOMAIN}/devhub" ;;
            templates) url="http://forgejo-http.forgejo.svc.cluster.local:3000/devhub-templates" ;;
        esac
        kubectl create secret generic "repo-creds-forgejo-${name}" -n argocd \
            --from-literal=type=git \
            --from-literal=url="$url" \
            --from-literal=username="$admin_user" \
            --from-literal=password="$token" \
            --dry-run=client -o yaml \
            | kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml \
            | kubectl apply -f - >/dev/null
        log_info "repo-creds registered: ${url}"
    done
}

enable_gitops_platform() {
    log_step "Handing platform components over to ArgoCD..."

    if [[ -z "${GITOPS_REPO_URL:-}" ]]; then
        log_error "gitops.repoUrl is not set in ${OVERLAY_DIR}/config.yaml"
        exit 1
    fi

    if ! kubectl get crd applicationsets.argoproj.io &>/dev/null; then
        log_error "ArgoCD is not installed yet — run: ./deploy.sh --env ${ENV} argocd"
        exit 1
    fi

    local dir; dir="$(render_dir)"
    template_values "${ARGOCD_DIR}/platform-appset.yaml" "${dir}/platform-appset.yaml"
    kubectl apply -f "${dir}/platform-appset.yaml"

    # The app appsets clone through these; without them every generated
    # Application sits at ComparisonError against the signed-in-only Forgejo.
    ensure_argocd_repo_creds

    log_info "ApplicationSet 'platform-components' applied"
    log_warn "ArgoCD now owns: cert-manager, external-dns, external-secrets,"
    log_warn "monitoring, loki, tempo, alloy, headlamp, homepage, kyverno,"
    log_warn "reloader, woodpecker, velero."
    log_warn "Change them through git from now on — a manual 'helm upgrade' will be reverted."
    echo ""
    log_info "The Applications stay 'Unknown' until this environment's own GitOps"
    log_info "repository exists and ArgoCD can read it:"
    log_info "  ./devhub gitops-repo --env ${ENV}"
    log_info ""
    log_info "That creates ${GITOPS_REPO_URL}, pushes a standalone copy of the"
    log_info "platform into it, and registers the credentials with ArgoCD. The"
    log_info "environment is independent of devhub from that point on."
}

# Move platform credentials into Vault and let External Secrets deliver them.
move_platform_secrets_to_vault() {
    log_step "Switching platform secrets to Vault + External Secrets..."

    if ! kubectl get clustersecretstore vault-backend &>/dev/null; then
        log_error "ClusterSecretStore 'vault-backend' not found."
        log_error "Run: ./setup-vault.sh --env ${ENV} configure"
        exit 1
    fi

    # Seeding needs Vault admin access. setup-vault.sh already seeds during `all`
    # and then revokes the root token by design, so a missing token here usually
    # means the values are in Vault already — not that something is broken.
    local keys_file="${SCRIPT_ENV_DIR}/vault-init-keys.json"
    local have_admin=false
    if [[ -n "${VAULT_TOKEN:-}" ]]; then
        have_admin=true
    elif [[ -f "$keys_file" ]] && [[ -n "$(jq -r '.admin_token // .root_token // empty' "$keys_file")" ]]; then
        have_admin=true
    fi

    if $have_admin; then
        log_info "Seeding platform credentials into Vault..."
        "${SCRIPT_DIR}/setup-vault.sh" --env "$ENV" seed-secrets || {
            log_error "Could not seed platform secrets into Vault"
            exit 1
        }
    else
        log_info "No Vault admin token available — assuming secret/platform/* is already seeded."
        log_info "If an ExternalSecret below stays NotReady, seed with an admin token:"
        log_info "  VAULT_TOKEN=<token> ./deploy.sh --env ${ENV} platform-secrets"
    fi

    # ESO takes ownership of these secrets. They already exist (created during
    # bootstrap), and ESO refuses to adopt a Secret it did not create — so delete
    # the bootstrap copy now that Vault holds the value. ESO recreates it within
    # seconds; running pods keep their mounted copy until they restart.
    local pairs=(
        "keycloak keycloak-db-secret"
        "forgejo forgejo-db-secret"
        "monitoring grafana-admin-secret"
        "monitoring alertmanager-slack"
    )
    local ns name
    for pair in "${pairs[@]}"; do
        read -r ns name <<<"$pair"
        if kubectl get secret "$name" -n "$ns" &>/dev/null; then
            if [[ -z "$(kubectl get secret "$name" -n "$ns" -o jsonpath='{.metadata.labels.reconcile\.external-secrets\.io/managed}' 2>/dev/null)" ]]; then
                log_info "Releasing ${ns}/${name} to External Secrets"
                kubectl delete secret "$name" -n "$ns"
            fi
        fi
    done

    kubectl apply -f "${BASE_DIR}/devops/external-secrets/platform-secrets.yaml"

    log_info "Waiting for External Secrets to materialise..."
    local ok=true
    for pair in "${pairs[@]}"; do
        read -r ns name <<<"$pair"
        if ! kubectl wait --for=condition=Ready "externalsecret/${name}" -n "$ns" --timeout=90s &>/dev/null; then
            log_warn "ExternalSecret ${ns}/${name} is not ready yet"
            ok=false
        fi
    done

    if $ok; then
        log_info "Platform credentials now come from Vault (secret/platform/*)"
        log_info "Rotate with: vault kv put secret/platform/postgres forgejo-password=..."
        log_info "Reloader restarts the affected workloads once External Secrets syncs."
    else
        log_warn "Some ExternalSecrets are not ready — check: kubectl describe externalsecret -A"
    fi
}

# Envoy Gateway: the Gateway API implementation. The chart bundles the Gateway API
# CRDs, so this is the only install needed before Gateways and HTTPRoutes exist.
install_gateway() {
    log_step "Installing Envoy Gateway..."

    local values_args=$(get_values_args "gateway")

    helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
        --namespace envoy-gateway-system \
        --create-namespace \
        --version "$CHART_ENVOY_GATEWAY" \
        $values_args \
        --atomic --timeout 10m

    kubectl wait --for=condition=Available deploy/envoy-gateway \
        -n envoy-gateway-system --timeout=300s || true

    log_info "Envoy Gateway installed"
}

# The Gateway (listeners + TLS) and the HTTPRoutes that attach to it.
apply_gateway_routes() {
    log_step "Applying Gateway and HTTPRoutes..."

    kubectl create namespace gateway 2>/dev/null || true

    if [[ "$ENV" == "local" ]]; then
        # Local CA: every listener shares one wildcard secret, which has to live in
        # the Gateway's own namespace.
        kubectl create secret tls local-tls-secret -n gateway \
            --cert="${CERTS_DIR}/domains/local-dev.crt" \
            --key="${CERTS_DIR}/domains/local-dev.key" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    fi

    local dir; dir="$(render_dir)"
    template_values "${OVERLAY_DIR}/devops/gateway.yaml" "${dir}/gateway.yaml"
    kubectl apply -f "${dir}/gateway.yaml"

    template_values "${OVERLAY_DIR}/devops/httproutes.yaml" "${dir}/httproutes.yaml"
    kubectl apply -f "${dir}/httproutes.yaml"

    log_info "Gateway and routes applied"

    apply_hairpin_dns
}

# Pods cannot reach the platform's own public hostnames: Azure's load
# balancer does not hairpin traffic from its backends, so any server-side
# call to https://<service>.${DOMAIN} (Forgejo's OIDC discovery, Vault's
# issuer validation, Grafana's token exchange) times out. Rewrite the
# platform domain inside cluster DNS to the Envoy gateway Service — it
# serves the same certificates on 443, so external URLs stay honest
# everywhere while resolving to an in-cluster path.
apply_hairpin_dns() {
    # AKS merges coredns-custom *.override files into the default server block.
    # Other clouds manage their DNS differently (GKE runs kube-dns) — extend
    # per cloud as they are brought up; internal-URL overrides cover them today.
    [[ "$CLOUD" == "azure" ]] || return 0

    local envoy_svc
    envoy_svc="$(kubectl get svc -n envoy-gateway-system \
        -l gateway.envoyproxy.io/owning-gateway-name=devhub \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$envoy_svc" ]]; then
        log_warn "No Envoy gateway Service yet — skipping hairpin DNS (re-run 'deploy gateway' later)"
        return 0
    fi

    log_step "Pointing ${DOMAIN} at the gateway inside cluster DNS..."
    local domain_re="${DOMAIN//./\\.}"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  devhub-hairpin.override: |
    rewrite stop {
      name regex (.*\.)?${domain_re} ${envoy_svc}.envoy-gateway-system.svc.cluster.local
      answer auto
    }
EOF
    kubectl rollout restart deployment/coredns -n kube-system >/dev/null
    log_info "In-cluster DNS rewrites *.${DOMAIN} → ${envoy_svc} (hairpin-safe)"
}

# Kyverno turns the platform's guardrails into admission-time policy and generates
# quotas/limits/NetworkPolicies for application namespaces as they appear.
install_kyverno() {
    log_step "Installing Kyverno..."

    local values_args=$(get_values_args "kyverno")

    helm upgrade --install kyverno kyverno/kyverno \
        --namespace kyverno \
        --create-namespace \
        --version "$CHART_KYVERNO" \
        $values_args \
        --atomic --timeout 10m

    kubectl wait --for=condition=Available deploy \
        -l app.kubernetes.io/component=admission-controller \
        -n kyverno --timeout=300s || true

    local dir; dir="$(render_dir)"
    template_values "${BASE_DIR}/devops/kyverno/policies.yaml" "${dir}/kyverno-policies.yaml"
    kubectl apply -f "${dir}/kyverno-policies.yaml"

    log_info "Kyverno installed with platform policies"
}

# Reloader restarts workloads when a mounted Secret or ConfigMap changes — the
# other half of credential rotation.
install_reloader() {
    log_step "Installing Reloader..."

    local values_args=$(get_values_args "reloader")

    helm upgrade --install reloader stakater/reloader \
        --namespace reloader \
        --create-namespace \
        --version "$CHART_RELOADER" \
        $values_args \
        --atomic --timeout 5m

    log_info "Reloader installed"
}

# =============================================================================
# Orchestration
# =============================================================================

deploy_devops() {
    add_helm_repos
    create_devops_namespaces
    apply_scheduling_policies
    install_storage_class
    # Gateway API first: cert-manager's gateway-shim and external-dns's
    # gateway-httproute source both need the CRDs to exist.
    install_gateway
    # The Gateway object must exist before ArgoCD is installed: on the local
    # environment ArgoCD's hostAlias points at the Envoy data-plane service, which
    # only exists once a Gateway has been created. Routes whose backends are not
    # deployed yet simply report unresolved until they are.
    apply_gateway_routes
    # Monitoring before every other component: it owns the
    # ServiceMonitor/PrometheusRule CRDs, and nearly everything below ships a
    # ServiceMonitor in its values — helm refuses the whole release when the
    # CRD is missing ("no matches for kind ServiceMonitor").
    install_monitoring
    install_cert_manager
    install_external_dns
    install_cluster_autoscaler
    install_data_services
    install_vault
    install_external_secrets
    install_keycloak
    install_forgejo
    install_woodpecker
    configure_woodpecker_oauth
    install_argocd
    install_headlamp
    install_homepage
    install_portal
    install_velero
    install_kyverno
    install_reloader
    # Re-apply routes so any listener added later in the graph is attached.
    apply_gateway_routes
    # Network policies last: applying default-deny before the pods exist just
    # makes the rollout look broken while things converge.
    apply_network_policies
    apply_disruption_budgets
}

delete_devops() {
    log_step "Deleting DevOps platform..."

    helm uninstall velero -n velero 2>/dev/null || true
    helm uninstall headlamp -n headlamp 2>/dev/null || true
    helm uninstall homepage -n homepage 2>/dev/null || true
    kubectl delete securitypolicy homepage-oidc -n homepage 2>/dev/null || true
    kubectl delete deployment,service,serviceaccount,configmap -n portal -l app=portal 2>/dev/null || true
    kubectl delete securitypolicy portal-oidc -n portal 2>/dev/null || true
    kubectl delete -f "${BASE_DIR}/devops/headlamp/rbac.yaml" 2>/dev/null || true
    helm uninstall argocd -n argocd 2>/dev/null || true
    helm uninstall external-dns -n external-dns 2>/dev/null || true
    helm uninstall cluster-autoscaler -n kube-system 2>/dev/null || true
    helm uninstall woodpecker -n woodpecker 2>/dev/null || true
    helm uninstall forgejo -n forgejo 2>/dev/null || true
    helm uninstall kyverno -n kyverno 2>/dev/null || true
    helm uninstall reloader -n reloader 2>/dev/null || true
    helm uninstall prometheus -n monitoring 2>/dev/null || true
    helm uninstall loki -n monitoring 2>/dev/null || true
    helm uninstall tempo -n monitoring 2>/dev/null || true
    helm uninstall alloy -n monitoring 2>/dev/null || true
    kubectl delete -f "${BASE_DIR}/devops/vault/raft-snapshot-cronjob.yaml" 2>/dev/null || true
    helm uninstall vault -n vault 2>/dev/null || true
    kubectl delete keycloak keycloak -n keycloak 2>/dev/null || true
    kubectl delete -n keycloak -f "${KEYCLOAK_MANIFEST_BASE}/kubernetes.yml" 2>/dev/null || true
    helm uninstall envoy-gateway -n envoy-gateway-system 2>/dev/null || true
    helm uninstall external-secrets -n external-secrets 2>/dev/null || true
    helm uninstall cert-manager -n cert-manager 2>/dev/null || true

    kubectl delete -f "${BASE_DIR}/devops/policy/network-policies.yaml" 2>/dev/null || true
    kubectl delete -f "${BASE_DIR}/devops/policy/pod-disruption-budgets.yaml" 2>/dev/null || true

    if [[ "$DATA_SERVICES_TYPE" == "local" ]]; then
        local DATA_SERVICES_DIR="${OVERLAY_DIR}/data-services"
        kubectl delete -f "${DATA_SERVICES_DIR}/minio.yaml" 2>/dev/null || true
        kubectl delete -f "${DATA_SERVICES_DIR}/valkey.yaml" 2>/dev/null || true
        kubectl delete -f "${DATA_SERVICES_DIR}/postgresql.yaml" 2>/dev/null || true
    fi

    log_info "DevOps platform deleted"
}

status_devops() {
    log_step "DevOps Platform Status:"
    echo ""
    for ns in data-services keycloak vault forgejo woodpecker woodpecker-ci argocd monitoring \
              external-secrets cert-manager external-dns headlamp homepage portal velero kyverno envoy-gateway-system; do
        echo "=== ${ns} ==="
        kubectl get pods -n "$ns" 2>/dev/null || echo "  Namespace not found"
        echo ""
    done

    echo "=== Vault seal status ==="
    kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
        vault status 2>/dev/null | grep -E 'Seal Type|Initialized|Sealed' || echo "  Vault not reachable"
    echo ""

    echo "=== Backups ==="
    kubectl get schedules.velero.io -n velero 2>/dev/null || echo "  Velero not installed"
    kubectl get cronjob -n vault 2>/dev/null || true
    echo ""

    echo "=== GitOps ==="
    kubectl get applicationset,application -n argocd 2>/dev/null || echo "  ArgoCD not installed"
}

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
    echo "  - Forgejo:    https://git.${DOMAIN}"
    echo "  - Woodpecker: https://ci.${DOMAIN}"
    echo "  - ArgoCD:     https://argocd.${DOMAIN}"
    echo "  - Headlamp:   https://headlamp.${DOMAIN}"
    echo "  - Homepage:   https://home.${DOMAIN}   (start here)"
    echo "  - Portal:     https://portal.${DOMAIN}   (scaffold a new app)"
    echo ""
    echo "Credentials:"
    echo "  Keycloak:  kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.password}' | base64 -d"
    echo "  Grafana:   kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d"
    echo "  ArgoCD:    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo "  Forgejo:   kubectl get secret forgejo-admin-secret -n forgejo -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    echo "Next steps:"
    echo "  1. ./setup-vault.sh --env ${ENV}            initialise Vault"
    echo "  2. ./setup-keycloak.sh --env ${ENV}         realm, groups, OIDC clients"
    echo "  3. ./deploy.sh --env ${ENV} platform-secrets  move credentials into Vault"
    echo "  4. ./deploy.sh --env ${ENV} bootstrap       ArgoCD app-of-apps"
    echo "  5. ./deploy.sh --env ${ENV} gitops         let ArgoCD own the platform"
    echo ""
    if [[ "$ENV" == "local" ]]; then
        echo "For Windows access, run (as Admin):"
        echo "  cd k8s/scripts/windows && .\\setup-all.ps1"
        echo ""
    fi
}

usage() {
    echo "Usage: $0 --env <env> [component] [action]"
    echo ""
    echo "Components:"
    echo "  all | devops       Deploy the entire platform"
    echo "  data-services, keycloak, vault, monitoring, forgejo, woodpecker, argocd,"
    echo "  headlamp, homepage, portal, external-dns, external-secrets, velero,"
    echo "  cluster-autoscaler, storage, policies, ingress"
    echo "  portal-token       (Re)mint the portal's Forgejo API token"
    echo "  portal-templates   (Re)publish the app template into Forgejo"
    echo "  ci-secrets         Woodpecker org registry secrets + portal CI activation"
    echo "                     (WOODPECKER_TOKEN=<token from https://ci.<domain>/user>)"
    echo "  db-users           Create managed-PostgreSQL users (once per database)"
    echo "  loki-auth          (Re)generate Loki ingest credentials + ingress"
    echo "  platform-secrets   Move platform credentials into Vault + ExternalSecrets"
    echo "  bootstrap          Deploy the ArgoCD app-of-apps"
    echo "  gitops             Hand platform components over to ArgoCD"
    echo ""
    echo "Actions: deploy (default), status, delete"
}

main() {
    echo "=============================================="
    echo "Kubernetes Deploy: ${ENV} / ${COMPONENT} / ${ACTION}"
    echo "=============================================="

    check_requirements
    require_cluster_match

    # cleanup-apps reads its own second argument (apply | dry-run), which is
    # not one of the deploy/status/delete actions.
    if [[ "$COMPONENT" == "cleanup-apps" ]]; then
        cleanup_orphaned_app_namespaces "$([ "$ACTION" == "apply" ] && echo apply || echo dry-run)"
        return 0
    fi

    case "$ACTION" in
        deploy)
            case "$COMPONENT" in
                all|devops)          deploy_devops; print_summary ;;
                bootstrap)           bootstrap_argocd_apps ;;
                gitops)              enable_gitops_platform ;;
                platform-secrets)    move_platform_secrets_to_vault ;;
                db-users)            create_db_users ;;
                loki-auth)           setup_loki_auth ;;
                data-services)       install_data_services ;;
                storage)             install_storage_class ;;
                policies)            apply_scheduling_policies && apply_network_policies && apply_disruption_budgets ;;
                keycloak)            add_helm_repos && install_keycloak ;;
                vault)               add_helm_repos && install_vault ;;
                monitoring)          add_helm_repos && install_monitoring ;;
                forgejo)             add_helm_repos && install_forgejo ;;
                woodpecker)          add_helm_repos && install_woodpecker && configure_woodpecker_oauth ;;
                woodpecker-oauth)    configure_woodpecker_oauth ;;
                gateway)             add_helm_repos && install_gateway && apply_gateway_routes ;;
                kyverno)             add_helm_repos && install_kyverno ;;
                reloader)            add_helm_repos && install_reloader ;;
                argocd)              add_helm_repos && install_argocd ;;
                headlamp)            add_helm_repos && install_headlamp ;;
                headlamp-token)      print_headlamp_token ;;
                homepage)            add_helm_repos && install_homepage ;;
                portal)              install_portal ;;
                portal-token)        ensure_portal_forgejo_token ;;
                portal-templates)    publish_app_templates ;;
                app-repo-creds)      ensure_argocd_repo_creds ;;
                ci-secrets)          configure_woodpecker_ci_secrets ;;
                external-dns)        add_helm_repos && install_external_dns ;;
                external-secrets)    add_helm_repos && install_external_secrets ;;
                velero)              add_helm_repos && install_velero ;;
                cluster-autoscaler)  add_helm_repos && install_cluster_autoscaler ;;
                routes)              apply_gateway_routes ;;
                *)
                    log_error "Unknown component: $COMPONENT"
                    usage
                    exit 1
                    ;;
            esac
            ;;
        status)
            status_devops
            ;;
        delete)
            case "$COMPONENT" in
                all|devops) delete_devops ;;
                *)
                    log_error "Delete is only supported for 'all' / 'devops'"
                    exit 1
                    ;;
            esac
            ;;
        *)
            log_error "Unknown action: $ACTION"
            usage
            exit 1
            ;;
    esac
}

main
