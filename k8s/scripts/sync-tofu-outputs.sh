#!/bin/bash
set -euo pipefail

# =============================================================================
# Sync OpenTofu Outputs to Generated Env Files
# =============================================================================
# Reads tofu outputs for an environment and writes them to two generated,
# gitignored files next to the environment's kubeconfig:
#
#   scripts/<env>/tofu-outputs.env   non-secret infrastructure values
#   scripts/<env>/secrets.env        credentials (chmod 600)
#
# config.yaml is NOT modified. It stays a human-owned file (domain, TLS,
# toggles) which means tofu applies no longer produce git diffs, and Helm
# templating no longer depends on grep/sed round-trips through YAML.
#
# Usage: ./sync-tofu-outputs.sh --env <environment>
#
# Platform environments: upcloud-dev, upcloud-prod, azure-dev, azure-prod,
#                        gcp-dev, gcp-prod, aws-dev, aws-prod
# Workload environments: upcloud-workload, azure-workload, gcp-workload, aws-workload
#
# Prerequisites:
#   - tofu apply has been run in the corresponding tofu environment
#   - Cloud CLI installed (upctl / az / gcloud / aws) for kubeconfig fetch
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
setup_paths

# Map k8s env to tofu directory, provider, and cluster type
REPO_ROOT="${SCRIPT_DIR}/../.."
CLOUD="$(env_cloud)"

if is_workload_env; then
    CLUSTER_TYPE="workload"
    TOFU_DIR="${REPO_ROOT}/tofu/${CLOUD}/workload"
else
    CLUSTER_TYPE="platform"
    case "$ENV" in
        *-dev)  TOFU_DIR="${REPO_ROOT}/tofu/${CLOUD}/dev" ;;
        *-prod) TOFU_DIR="${REPO_ROOT}/tofu/${CLOUD}/prod" ;;
        *)
            log_error "sync-tofu-outputs only works with managed cloud environments"
            log_error "Platform: ${PLATFORM_ENVS// local/}"
            log_error "Workload: ${WORKLOAD_ENVS}"
            exit 1
            ;;
    esac
fi

CONFIG_FILE="${OVERLAY_DIR}/config.yaml"
OUTPUTS_FILE="${SCRIPT_ENV_DIR}/tofu-outputs.env"
SECRETS_FILE="${SCRIPT_ENV_DIR}/secrets.env"
MANUAL_FILE="${SCRIPT_ENV_DIR}/manual-secrets.env"

[[ -d "$TOFU_DIR" ]] || { log_error "Tofu directory not found: $TOFU_DIR"; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { log_error "Config file not found: $CONFIG_FILE"; exit 1; }

# ─── Read tofu outputs ──────────────────────────────────────────────

log_step "Reading tofu outputs from ${TOFU_DIR}..."

cd "$TOFU_DIR"

if [[ ! -f terraform.tfstate ]] && [[ ! -d .terraform ]]; then
    log_error "Tofu has not been initialized/applied in ${TOFU_DIR}"
    log_error "Run: cd ${TOFU_DIR} && tofu init -backend-config=backend.hcl && tofu apply"
    exit 1
fi

OUTPUTS="$(tofu output -json)"

# out <output_name> — value or empty string when the output does not exist.
out() { echo "$OUTPUTS" | jq -r --arg k "$1" 'if has($k) then .[$k].value | tostring else "" end'; }

CLUSTER_NAME="$(out cluster_name)"
[[ -n "$CLUSTER_NAME" ]] || { log_error "tofu output cluster_name is empty — has apply completed?"; exit 1; }

# ─── Compose the generated files ────────────────────────────────────

# Values are written as KEY=value pairs, quoted, so the files can be sourced.
declare -a PUBLIC_VARS=()
declare -a SECRET_VARS=()

add_public() { [[ -n "${2:-}" ]] && PUBLIC_VARS+=("$1=$2"); return 0; }
add_secret() { [[ -n "${2:-}" ]] && SECRET_VARS+=("$1=$2"); return 0; }

add_public CLUSTER_NAME "$CLUSTER_NAME"
add_public OIDC_ISSUER_URL "$(out oidc_issuer_url)"

case "$CLOUD" in
    aws)
        AWS_REGION="$(out aws_region)"
        add_public AWS_REGION "$AWS_REGION"
        add_public S3_REGION "$AWS_REGION"
        add_public EXTERNAL_DNS_IRSA_ROLE_ARN "$(out external_dns_irsa_role_arn)"
        add_public EBS_CSI_ROLE_ARN "$(out ebs_csi_role_arn)"

        if [[ "$CLUSTER_TYPE" == "platform" ]]; then
            add_public PG_HOST "$(out pg_host)"
            add_public PG_PORT "$(out pg_port)"
            add_public REDIS_HOST "$(out redis_host)"
            add_public REDIS_PORT "$(out redis_port)"
            add_public REDIS_TLS_ENABLED "$(out redis_tls_enabled)"
            add_public LOKI_IRSA_ROLE_ARN "$(out loki_irsa_role_arn)"
            add_public LOKI_BUCKET "$(out loki_bucket)"
            add_public VELERO_IRSA_ROLE_ARN "$(out velero_irsa_role_arn)"
            add_public VELERO_BUCKET "$(out velero_bucket)"
            add_public CLUSTER_AUTOSCALER_IRSA_ROLE_ARN "$(out cluster_autoscaler_irsa_role_arn)"
            add_public VAULT_KMS_KEY_ID "$(out vault_kms_key_id)"
            add_public VAULT_KMS_IRSA_ROLE_ARN "$(out vault_kms_irsa_role_arn)"
            add_public COGNITO_ISSUER_URL "$(out cognito_issuer_url)"
            add_public COGNITO_HOSTED_UI_DOMAIN "$(out cognito_hosted_ui_domain)"
            add_public COGNITO_CLIENT_ID "$(out cognito_client_id)"
            add_public COGNITO_USER_POOL_ID "$(out cognito_user_pool_id)"

            add_secret PG_ADMIN_LOGIN "$(out pg_admin_login)"
            add_secret PG_ADMIN_PASSWORD "$(out pg_admin_password)"
            add_secret PG_KEYCLOAK_PASSWORD "$(out pg_keycloak_password)"
            add_secret PG_FORGEJO_PASSWORD "$(out pg_forgejo_password)"
            add_secret REDIS_PASSWORD "$(out redis_auth_token)"
            add_secret COGNITO_CLIENT_SECRET "$(out cognito_client_secret)"
        fi
        ;;

    azure)
        add_public AZURE_RESOURCE_GROUP "$(out resource_group_name)"
        add_public AZURE_LOCATION "$(out location)"
        add_public EXTERNAL_DNS_IDENTITY_CLIENT_ID "$(out external_dns_identity_client_id)"

        if [[ "$CLUSTER_TYPE" == "platform" ]]; then
            add_public AZURE_SUBSCRIPTION_ID "$(out subscription_id)"
            add_public AZURE_NODE_RESOURCE_GROUP "$(out node_resource_group)"
            add_public PG_HOST "$(out pg_host)"
            add_public PG_PORT "$(out pg_port)"
            add_public REDIS_HOST "$(out redis_host)"
            add_public REDIS_PORT "$(out redis_port)"
            add_public REDIS_TLS_ENABLED "true"
            add_public AZURE_STORAGE_ACCOUNT "$(out storage_account_name)"
            add_public LOKI_IDENTITY_CLIENT_ID "$(out loki_identity_client_id)"
            add_public LOKI_CONTAINER "$(out loki_container)"
            add_public VELERO_IDENTITY_CLIENT_ID "$(out velero_identity_client_id)"
            add_public VELERO_CONTAINER "$(out velero_container)"
            add_public VAULT_KEY_VAULT_NAME "$(out vault_key_vault_name)"
            add_public VAULT_KEY_NAME "$(out vault_key_name)"
            add_public VAULT_IDENTITY_CLIENT_ID "$(out vault_identity_client_id)"
            add_public ENTRA_TENANT_ID "$(out entra_tenant_id)"
            add_public ENTRA_KEYCLOAK_CLIENT_ID "$(out entra_keycloak_client_id)"

            add_secret PG_ADMIN_LOGIN "$(out pg_admin_login)"
            add_secret PG_ADMIN_PASSWORD "$(out pg_admin_password)"
            add_secret PG_KEYCLOAK_PASSWORD "$(out pg_keycloak_password)"
            add_secret PG_FORGEJO_PASSWORD "$(out pg_forgejo_password)"
            add_secret REDIS_PASSWORD "$(out redis_password)"
            add_secret AZURE_STORAGE_KEY "$(out storage_primary_access_key)"
            add_secret ENTRA_KEYCLOAK_CLIENT_SECRET "$(out entra_keycloak_client_secret)"
        fi
        ;;

    gcp)
        add_public GCS_PROJECT_ID "$(out project_id)"
        add_public GCP_REGION "$(out region)"
        add_public EXTERNAL_DNS_GSA_EMAIL "$(out external_dns_gsa_email)"

        if [[ "$CLUSTER_TYPE" == "platform" ]]; then
            add_public PG_HOST "$(out pg_host)"
            add_public PG_PORT "$(out pg_port)"
            add_public REDIS_HOST "$(out redis_host)"
            add_public REDIS_PORT "$(out redis_port)"
            add_public LOKI_GSA_EMAIL "$(out loki_gsa_email)"
            add_public LOKI_BUCKET "$(out loki_bucket)"
            add_public VELERO_GSA_EMAIL "$(out velero_gsa_email)"
            add_public VELERO_BUCKET "$(out velero_bucket)"
            add_public VAULT_GSA_EMAIL "$(out vault_gsa_email)"
            add_public VAULT_KMS_REGION "$(out vault_kms_region)"
            add_public VAULT_KMS_KEY_RING "$(out vault_kms_key_ring)"
            add_public VAULT_KMS_CRYPTO_KEY "$(out vault_kms_crypto_key)"

            add_secret PG_ADMIN_LOGIN "$(out pg_admin_login)"
            add_secret PG_ADMIN_PASSWORD "$(out pg_admin_password)"
            add_secret PG_KEYCLOAK_PASSWORD "$(out pg_keycloak_password)"
            add_secret PG_FORGEJO_PASSWORD "$(out pg_forgejo_password)"
            add_secret REDIS_PASSWORD "$(out redis_auth_string)"
        fi
        ;;

    upcloud)
        add_public UPCLOUD_ZONE "$(out zone)"

        if [[ "$CLUSTER_TYPE" == "platform" ]]; then
            add_public PG_HOST "$(out pg_host)"
            add_public PG_PORT "$(out pg_port)"
            add_public VALKEY_HOST "$(out valkey_host)"
            add_public VALKEY_PORT "$(out valkey_port)"
            add_public S3_ENDPOINT "$(out s3_endpoint)"
            add_public S3_REGION "$(out s3_region)"
            add_public LOKI_BUCKET "$(out loki_bucket)"
            add_public VELERO_BUCKET "$(out velero_bucket)"

            add_secret PG_KEYCLOAK_PASSWORD "$(out pg_keycloak_password)"
            add_secret PG_FORGEJO_PASSWORD "$(out pg_forgejo_password)"
            add_secret REDIS_PASSWORD "$(out valkey_password)"
            # No workload identity on UpCloud — bucket-scoped access keys instead.
            # deploy.sh turns these into Kubernetes Secrets; they never enter
            # values files or git.
            add_secret LOKI_S3_ACCESS_KEY_ID "$(out loki_s3_access_key_id)"
            add_secret LOKI_S3_SECRET_ACCESS_KEY "$(out loki_s3_secret_access_key)"
            add_secret VELERO_S3_ACCESS_KEY_ID "$(out velero_s3_access_key_id)"
            add_secret VELERO_S3_SECRET_ACCESS_KEY "$(out velero_s3_secret_access_key)"
        fi
        ;;
esac

# ─── Write generated files ──────────────────────────────────────────

log_step "Writing generated env files..."

{
    echo "# Generated by sync-tofu-outputs.sh — do not edit, do not commit."
    echo "# Source: ${TOFU_DIR}"
    echo "# Environment: ${ENV}"
    printf '%s\n' "${PUBLIC_VARS[@]}"
} > "$OUTPUTS_FILE"
chmod 600 "$OUTPUTS_FILE"
log_info "Infrastructure values: ${OUTPUTS_FILE} (${#PUBLIC_VARS[@]} values)"

if [[ ${#SECRET_VARS[@]} -gt 0 ]]; then
    {
        echo "# Generated by sync-tofu-outputs.sh — CONTAINS CREDENTIALS."
        echo "# Never commit. deploy.sh reads this to create the platform's K8s secrets."
        echo "# Environment: ${ENV}"
        printf '%s\n' "${SECRET_VARS[@]}"
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    log_info "Credentials:           ${SECRETS_FILE} (${#SECRET_VARS[@]} values)"
fi

# Secrets that tofu cannot create (no provider resource exists) go in a file we
# create once and never overwrite, so a manual value is never clobbered.
if [[ "$CLUSTER_TYPE" == "platform" && ! -f "$MANUAL_FILE" ]]; then
    case "$CLOUD" in
        gcp)
            cat > "$MANUAL_FILE" <<'EOF'
# Manually-provided secrets (not managed by tofu).
#
# Google OAuth client for Keycloak's Google identity provider. There is no
# Terraform resource for OAuth clients, so create one by hand:
#   Google Cloud Console → APIs & Services → Credentials
#   → Create OAuth client ID → Web application
#   Authorized redirect URI:
#     https://keycloak.<domain>/realms/devops/broker/google/endpoint
GOOGLE_IDP_CLIENT_ID=FILL_IN_MANUALLY
GOOGLE_IDP_CLIENT_SECRET=FILL_IN_MANUALLY
EOF
            ;;
        *)
            cat > "$MANUAL_FILE" <<'EOF'
# Manually-provided secrets (not managed by tofu).
# Add values here as needed; this file is never overwritten by sync-tofu-outputs.sh.
EOF
            ;;
    esac
    chmod 600 "$MANUAL_FILE"
    log_info "Manual secrets template: ${MANUAL_FILE}"
fi

# ─── Fetch kubeconfig ────────────────────────────────────────────────

log_step "Fetching kubeconfig for cluster: ${CLUSTER_NAME}..."

KUBECONFIG_FILE="${SCRIPT_ENV_DIR}/kubeconfig"

fetch_kubeconfig() {
    case "$CLOUD" in
        aws)
            local region
            region="$(out aws_region)"
            if command -v aws &>/dev/null; then
                aws eks update-kubeconfig --region "$region" --name "$CLUSTER_NAME" \
                    --kubeconfig "$KUBECONFIG_FILE"
            else
                log_warn "aws CLI not found — run:"
                log_warn "  aws eks update-kubeconfig --region ${region} --name ${CLUSTER_NAME} --kubeconfig ${KUBECONFIG_FILE}"
                return 1
            fi
            ;;
        azure)
            local rg
            rg="$(out resource_group_name)"
            if command -v az &>/dev/null; then
                az aks get-credentials --resource-group "$rg" --name "$CLUSTER_NAME" \
                    --file "$KUBECONFIG_FILE" --overwrite-existing
            else
                log_warn "az CLI not found — run:"
                log_warn "  az aks get-credentials --resource-group ${rg} --name ${CLUSTER_NAME} --file ${KUBECONFIG_FILE}"
                return 1
            fi
            ;;
        gcp)
            local region project
            region="$(out region)"
            project="$(out project_id)"
            if command -v gcloud &>/dev/null; then
                KUBECONFIG="$KUBECONFIG_FILE" gcloud container clusters get-credentials \
                    "$CLUSTER_NAME" --region "$region" --project "$project"
            else
                log_warn "gcloud not found — run:"
                log_warn "  KUBECONFIG=${KUBECONFIG_FILE} gcloud container clusters get-credentials ${CLUSTER_NAME} --region ${region} --project ${project}"
                return 1
            fi
            ;;
        upcloud)
            if command -v upctl &>/dev/null; then
                upctl kubernetes config "$CLUSTER_NAME" --write "$KUBECONFIG_FILE"
            else
                log_warn "upctl not found — download the kubeconfig from the UpCloud console and save it to:"
                log_warn "  ${KUBECONFIG_FILE}"
                return 1
            fi
            ;;
    esac
}

if fetch_kubeconfig; then
    chmod 600 "$KUBECONFIG_FILE"
    log_info "Kubeconfig written to: ${KUBECONFIG_FILE}"
fi

# ─── Summary ─────────────────────────────────────────────────────────

echo ""
log_info "Sync complete. Next steps:"
echo ""
echo "  1. Confirm domain / acmeEmail in: ${CONFIG_FILE}"
if [[ "$CLUSTER_TYPE" == "workload" ]]; then
    echo "  2. Set platformVaultUrl and platformLokiUrl in: ${CONFIG_FILE}"
    echo "  3. ./deploy-workload.sh --env ${ENV}"
    echo "  4. ./register-workload-cluster.sh --env ${ENV}"
else
    if [[ "$CLOUD" != "upcloud" ]]; then
        echo "  2. Create the managed-PostgreSQL users (once per new database):"
        echo "       ./deploy.sh --env ${ENV} db-users"
    fi
    if [[ "$CLOUD" == "gcp" ]]; then
        echo "  3. Fill in the Google OAuth client in: ${MANUAL_FILE}"
    fi
    echo "  4. ./deploy.sh --env ${ENV}"
fi
echo ""
echo "  Generated files (gitignored): ${SCRIPT_ENV_DIR}/"
echo ""
