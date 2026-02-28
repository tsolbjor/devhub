#!/bin/bash
set -euo pipefail

# =============================================================================
# Sync OpenTofu Outputs to K8s Overlay Config
# =============================================================================
# Reads managed data service outputs from tofu and writes them into the
# matching k8s overlay config.yaml. Also fetches the cluster kubeconfig.
#
# Usage: ./sync-tofu-outputs.sh --env upcloud-dev|upcloud-prod|azure-dev|azure-prod
#
# Prerequisites:
#   - tofu apply has been run in the corresponding tofu environment
#   - upctl CLI installed (for UpCloud kubeconfig fetch)
#   - az CLI installed (for Azure kubeconfig fetch)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"

# Map k8s env to tofu directory and provider
REPO_ROOT="${SCRIPT_DIR}/../.."
case "$ENV" in
    upcloud-dev)  TOFU_DIR="${REPO_ROOT}/tofu/upcloud/dev";  CLOUD="upcloud" ;;
    upcloud-prod) TOFU_DIR="${REPO_ROOT}/tofu/upcloud/prod"; CLOUD="upcloud" ;;
    azure-dev)    TOFU_DIR="${REPO_ROOT}/tofu/azure/dev";    CLOUD="azure" ;;
    azure-prod)   TOFU_DIR="${REPO_ROOT}/tofu/azure/prod";   CLOUD="azure" ;;
    gcp-dev)      TOFU_DIR="${REPO_ROOT}/tofu/gcp/dev";      CLOUD="gcp" ;;
    gcp-prod)     TOFU_DIR="${REPO_ROOT}/tofu/gcp/prod";     CLOUD="gcp" ;;
    aws-dev)      TOFU_DIR="${REPO_ROOT}/tofu/aws/dev";      CLOUD="aws" ;;
    aws-prod)     TOFU_DIR="${REPO_ROOT}/tofu/aws/prod";     CLOUD="aws" ;;
    *)
        log_error "sync-tofu-outputs only works with upcloud-dev, upcloud-prod, azure-dev, azure-prod, gcp-dev, gcp-prod, aws-dev, or aws-prod"
        exit 1
        ;;
esac

CONFIG_FILE="${SCRIPT_DIR}/../overlays/${ENV}/config.yaml"

if [[ ! -d "$TOFU_DIR" ]]; then
    log_error "Tofu directory not found: $TOFU_DIR"
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
fi

# ─── Read tofu outputs ──────────────────────────────────────────────

log_step "Reading tofu outputs from ${TOFU_DIR}..."

cd "$TOFU_DIR"

if [[ ! -f terraform.tfstate ]] && [[ ! -d .terraform ]]; then
    log_error "Tofu has not been initialized/applied in ${TOFU_DIR}"
    log_error "Run: cd ${TOFU_DIR} && tofu init && tofu apply"
    exit 1
fi

OUTPUTS=$(tofu output -json)

PG_HOST=$(echo "$OUTPUTS" | jq -r '.pg_host.value')
PG_PORT=$(echo "$OUTPUTS" | jq -r '.pg_port.value')
CLUSTER_NAME=$(echo "$OUTPUTS" | jq -r '.cluster_name.value')

# ─── Cloud-specific output parsing ──────────────────────────────────

if [[ "$CLOUD" == "gcp" ]]; then
    REDIS_HOST=$(echo "$OUTPUTS" | jq -r '.redis_host.value')
    REDIS_PORT=$(echo "$OUTPUTS" | jq -r '.redis_port.value')
    REDIS_AUTH_STRING=$(echo "$OUTPUTS" | jq -r '.redis_auth_string.value')
    GCS_PROJECT_ID=$(echo "$OUTPUTS" | jq -r '.project_id.value')
    GCS_BUCKET_PREFIX=$(echo "$OUTPUTS" | jq -r '.gitlab_gcs_bucket_prefix.value')
    GITLAB_GSA_EMAIL=$(echo "$OUTPUTS" | jq -r '.gitlab_gsa_email.value')
    GCP_REGION=$(echo "$OUTPUTS" | jq -r '.region.value')

    log_info "PostgreSQL:        ${PG_HOST}:${PG_PORT}"
    log_info "Redis:             ${REDIS_HOST}:${REDIS_PORT}"
    log_info "GCS Project:       ${GCS_PROJECT_ID}"
    log_info "GCS Bucket Prefix: ${GCS_BUCKET_PREFIX}"
    log_info "GitLab GSA:        ${GITLAB_GSA_EMAIL}"
    log_info "Cluster:           ${CLUSTER_NAME}"

elif [[ "$CLOUD" == "aws" ]]; then
    REDIS_HOST=$(echo "$OUTPUTS" | jq -r '.redis_host.value')
    REDIS_PORT=$(echo "$OUTPUTS" | jq -r '.redis_port.value')
    AWS_REGION=$(echo "$OUTPUTS" | jq -r '.aws_region.value')
    S3_BUCKET_PREFIX=$(echo "$OUTPUTS" | jq -r '.gitlab_s3_bucket_prefix.value')
    GITLAB_IRSA_ROLE_ARN=$(echo "$OUTPUTS" | jq -r '.gitlab_irsa_role_arn.value')
    COGNITO_ISSUER_URL=$(echo "$OUTPUTS" | jq -r '.cognito_issuer_url.value')
    COGNITO_HOSTED_UI_DOMAIN=$(echo "$OUTPUTS" | jq -r '.cognito_hosted_ui_domain.value')
    COGNITO_CLIENT_ID=$(echo "$OUTPUTS" | jq -r '.cognito_client_id.value')
    COGNITO_CLIENT_SECRET=$(echo "$OUTPUTS" | jq -r '.cognito_client_secret.value')

    log_info "PostgreSQL:          ${PG_HOST}:${PG_PORT}"
    log_info "Redis:               ${REDIS_HOST}:${REDIS_PORT}"
    log_info "S3 Region:           ${AWS_REGION}"
    log_info "S3 Bucket Prefix:    ${S3_BUCKET_PREFIX}"
    log_info "GitLab IRSA ARN:     ${GITLAB_IRSA_ROLE_ARN}"
    log_info "Cognito Issuer:      ${COGNITO_ISSUER_URL}"
    log_info "Cognito Domain:      ${COGNITO_HOSTED_UI_DOMAIN}"
    log_info "Cognito Client:      ${COGNITO_CLIENT_ID}"
    log_info "Cluster:             ${CLUSTER_NAME}"

elif [[ "$CLOUD" == "upcloud" ]]; then
    VALKEY_HOST=$(echo "$OUTPUTS" | jq -r '.valkey_host.value')
    VALKEY_PORT=$(echo "$OUTPUTS" | jq -r '.valkey_port.value')
    S3_ENDPOINT=$(echo "$OUTPUTS" | jq -r '.s3_endpoint.value')
    S3_REGION=$(echo "$OUTPUTS" | jq -r '.s3_region.value')

    log_info "PostgreSQL: ${PG_HOST}:${PG_PORT}"
    log_info "Valkey:     ${VALKEY_HOST}:${VALKEY_PORT}"
    log_info "S3:         ${S3_ENDPOINT} (${S3_REGION})"
    log_info "Cluster:    ${CLUSTER_NAME}"
else
    REDIS_HOST=$(echo "$OUTPUTS" | jq -r '.redis_host.value')
    REDIS_PORT=$(echo "$OUTPUTS" | jq -r '.redis_port.value')
    STORAGE_ACCOUNT=$(echo "$OUTPUTS" | jq -r '.storage_account_name.value')
    GITLAB_IDENTITY_CLIENT_ID=$(echo "$OUTPUTS" | jq -r '.gitlab_identity_client_id.value')
    RESOURCE_GROUP=$(echo "$OUTPUTS" | jq -r '.resource_group_name.value')
    ENTRA_TENANT_ID=$(echo "$OUTPUTS" | jq -r '.entra_tenant_id.value')
    ENTRA_KEYCLOAK_CLIENT_ID=$(echo "$OUTPUTS" | jq -r '.entra_keycloak_client_id.value')
    ENTRA_KEYCLOAK_CLIENT_SECRET=$(echo "$OUTPUTS" | jq -r '.entra_keycloak_client_secret.value')

    log_info "PostgreSQL:       ${PG_HOST}:${PG_PORT}"
    log_info "Redis:            ${REDIS_HOST}:${REDIS_PORT}"
    log_info "Storage Account:  ${STORAGE_ACCOUNT}"
    log_info "GitLab Identity:  ${GITLAB_IDENTITY_CLIENT_ID}"
    log_info "Entra Tenant:     ${ENTRA_TENANT_ID}"
    log_info "Entra Client:     ${ENTRA_KEYCLOAK_CLIENT_ID}"
    log_info "Cluster:          ${CLUSTER_NAME}"
fi

# ─── Update config.yaml ─────────────────────────────────────────────

log_step "Updating ${CONFIG_FILE}..."

if [[ "$CLOUD" == "gcp" ]]; then
    sed -i "/^dataServices:/,\$ {
        /postgresql:/,/host:/ { s|host: .*|host: ${PG_HOST}:${PG_PORT}| }
        /redis:/,/host:/ { s|host: .*|host: ${REDIS_HOST}| }
        /gcs:/,/projectId:/ { s|projectId: .*|projectId: ${GCS_PROJECT_ID}| }
        /gcs:/,/bucketPrefix:/ { s|bucketPrefix: .*|bucketPrefix: ${GCS_BUCKET_PREFIX}| }
        /gcs:/,/gitlabGsaEmail:/ { s|gitlabGsaEmail: .*|gitlabGsaEmail: ${GITLAB_GSA_EMAIL}| }
    }" "$CONFIG_FILE"

    # Write Google IdP client secret template (fill in manually after creating OAuth client)
    google_idp_file="${SCRIPT_DIR}/${ENV}/gcp-idp.env"
    mkdir -p "${SCRIPT_DIR}/${ENV}"
    if [[ ! -f "$google_idp_file" ]]; then
        cat > "$google_idp_file" <<EOF
# GCP IdP credentials for Keycloak Google social login
# Create a Web Application OAuth client in Google Cloud Console:
#   APIs & Services → Credentials → Create OAuth client ID → Web application
#   Authorized redirect URIs: https://keycloak.<domain>/realms/devops/broker/google/endpoint
# Then fill in GOOGLE_IDP_CLIENT_ID and GOOGLE_IDP_CLIENT_SECRET below.
GOOGLE_IDP_CLIENT_ID=FILL_IN_MANUALLY
GOOGLE_IDP_CLIENT_SECRET=FILL_IN_MANUALLY
EOF
        chmod 600 "$google_idp_file"
        log_info "Google IdP template written to: ${google_idp_file}"
        log_info "Fill in the client ID/secret after creating the OAuth app in Google Cloud Console"
    else
        log_info "gcp-idp.env already exists — not overwriting"
    fi

    # Write Memorystore Redis auth string to secrets file
    redis_secrets_file="${SCRIPT_DIR}/${ENV}/gcp-redis.env"
    cat > "$redis_secrets_file" <<EOF
REDIS_AUTH_STRING=${REDIS_AUTH_STRING}
EOF
    chmod 600 "$redis_secrets_file"
    log_info "Redis auth string written to: ${redis_secrets_file}"
    log_info "Create K8s secret: kubectl create secret generic gitlab-redis-secret -n gitlab --from-literal=password=${REDIS_AUTH_STRING}"

elif [[ "$CLOUD" == "aws" ]]; then
    sed -i "/^dataServices:/,\$ {
        /postgresql:/,/host:/ { s|host: .*|host: ${PG_HOST}:${PG_PORT}| }
        /redis:/,/host:/ { s|host: .*|host: ${REDIS_HOST}| }
        /s3:/,/region:/ { s|region: .*|region: ${AWS_REGION}| }
        /s3:/,/bucketPrefix:/ { s|bucketPrefix: .*|bucketPrefix: ${S3_BUCKET_PREFIX}| }
        /s3:/,/gitlabIrsaRoleArn:/ { s|gitlabIrsaRoleArn: .*|gitlabIrsaRoleArn: ${GITLAB_IRSA_ROLE_ARN}| }
    }" "$CONFIG_FILE"

    # Write non-sensitive Cognito values into config.yaml
    sed -i "/^cognitoIdp:/,\$ {
        s|issuerUrl: .*|issuerUrl: ${COGNITO_ISSUER_URL}|
        s|hostedUiDomain: .*|hostedUiDomain: ${COGNITO_HOSTED_UI_DOMAIN}|
        s|clientId: .*|clientId: ${COGNITO_CLIENT_ID}|
    }" "$CONFIG_FILE"

    # Write Cognito client secret to local env file (gitignored, read by setup-keycloak.sh)
    aws_idp_file="${SCRIPT_DIR}/${ENV}/aws-idp.env"
    mkdir -p "${SCRIPT_DIR}/${ENV}"
    cat > "$aws_idp_file" <<EOF
COGNITO_ISSUER_URL=${COGNITO_ISSUER_URL}
COGNITO_HOSTED_UI_DOMAIN=${COGNITO_HOSTED_UI_DOMAIN}
COGNITO_CLIENT_ID=${COGNITO_CLIENT_ID}
COGNITO_CLIENT_SECRET=${COGNITO_CLIENT_SECRET}
EOF
    chmod 600 "$aws_idp_file"
    log_info "Cognito credentials written to: ${aws_idp_file}"

elif [[ "$CLOUD" == "upcloud" ]]; then
    # Context-aware replacement within the dataServices section
    sed -i "/^dataServices:/,\$ {
        /postgresql:/,/host:/ { s|host: .*|host: ${PG_HOST}:${PG_PORT}| }
        /valkey:/,/host:/ { s|host: .*|host: ${VALKEY_HOST}:${VALKEY_PORT}| }
        /s3:/,/endpoint:/ { s|endpoint: .*|endpoint: ${S3_ENDPOINT}| }
        /s3:/,/region:/ { s|region: .*|region: ${S3_REGION}| }
    }" "$CONFIG_FILE"
else
    sed -i "/^dataServices:/,\$ {
        /postgresql:/,/host:/ { s|host: .*|host: ${PG_HOST}:${PG_PORT}| }
        /redis:/,/host:/ { s|host: .*|host: ${REDIS_HOST}:${REDIS_PORT}| }
        s|accountName: .*|accountName: ${STORAGE_ACCOUNT}|
        s|identityClientId: .*|identityClientId: ${GITLAB_IDENTITY_CLIENT_ID}|
    }" "$CONFIG_FILE"

    # Write non-sensitive Entra values into config.yaml
    sed -i "/^entraId:/,\$ {
        s|tenantId: .*|tenantId: ${ENTRA_TENANT_ID}|
        s|clientId: .*|clientId: ${ENTRA_KEYCLOAK_CLIENT_ID}|
    }" "$CONFIG_FILE"

    # Write the client secret to a local env file (gitignored, read by setup-keycloak.sh)
    entra_secrets_file="${SCRIPT_DIR}/${ENV}/entra-idp.env"
    mkdir -p "${SCRIPT_DIR}/${ENV}"
    cat > "$entra_secrets_file" <<EOF
ENTRA_TENANT_ID=${ENTRA_TENANT_ID}
ENTRA_KEYCLOAK_CLIENT_ID=${ENTRA_KEYCLOAK_CLIENT_ID}
ENTRA_KEYCLOAK_CLIENT_SECRET=${ENTRA_KEYCLOAK_CLIENT_SECRET}
EOF
    chmod 600 "$entra_secrets_file"
    log_info "Entra ID credentials written to: ${entra_secrets_file}"
fi

log_info "Config updated"

# ─── Fetch kubeconfig ────────────────────────────────────────────────

log_step "Fetching kubeconfig for cluster: ${CLUSTER_NAME}..."

KUBECONFIG_DIR="${SCRIPT_DIR}/${ENV}"
mkdir -p "$KUBECONFIG_DIR"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/kubeconfig"

if [[ "$CLOUD" == "gcp" ]]; then
    if command -v gcloud &>/dev/null; then
        KUBECONFIG="${KUBECONFIG_FILE}" gcloud container clusters get-credentials "${CLUSTER_NAME}" \
            --region "${GCP_REGION}" \
            --project "${GCS_PROJECT_ID}"
        log_info "Kubeconfig written to: ${KUBECONFIG_FILE}"
        log_info "Use with: export KUBECONFIG=${KUBECONFIG_FILE}"
    else
        log_warn "gcloud not found — install Google Cloud SDK to fetch kubeconfig automatically"
        log_warn "  https://cloud.google.com/sdk/docs/install"
        log_warn "Or run: KUBECONFIG=${KUBECONFIG_FILE} gcloud container clusters get-credentials ${CLUSTER_NAME} --region ${GCP_REGION} --project ${GCS_PROJECT_ID}"
    fi

elif [[ "$CLOUD" == "aws" ]]; then
    if command -v aws &>/dev/null; then
        aws eks update-kubeconfig \
            --region "${AWS_REGION}" \
            --name "${CLUSTER_NAME}" \
            --kubeconfig "${KUBECONFIG_FILE}"
        log_info "Kubeconfig written to: ${KUBECONFIG_FILE}"
        log_info "Use with: export KUBECONFIG=${KUBECONFIG_FILE}"
    else
        log_warn "aws CLI not found — install AWS CLI to fetch kubeconfig automatically"
        log_warn "  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        log_warn "Or run: aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}"
    fi

elif [[ "$CLOUD" == "upcloud" ]]; then
    if command -v upctl &>/dev/null; then
        upctl kubernetes config "${CLUSTER_NAME}" --write "${KUBECONFIG_FILE}"
        log_info "Kubeconfig written to: ${KUBECONFIG_FILE}"
        log_info "Use with: export KUBECONFIG=${KUBECONFIG_FILE}"
    else
        log_warn "upctl not found — install UpCloud CLI to fetch kubeconfig automatically"
        log_warn "  https://github.com/UpCloudLtd/upcloud-cli"
        log_warn "Or download kubeconfig from UpCloud console and save to: ${KUBECONFIG_FILE}"
    fi
else
    if command -v az &>/dev/null; then
        az aks get-credentials \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}" \
            --file "${KUBECONFIG_FILE}" \
            --overwrite-existing
        log_info "Kubeconfig written to: ${KUBECONFIG_FILE}"
        log_info "Use with: export KUBECONFIG=${KUBECONFIG_FILE}"
    else
        log_warn "az not found — install Azure CLI to fetch kubeconfig automatically"
        log_warn "  https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
        log_warn "Or run: az aks get-credentials --resource-group ${RESOURCE_GROUP} --name ${CLUSTER_NAME}"
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────

echo ""
log_info "Sync complete. Next steps:"
echo ""
echo "  1. Set domain and acmeEmail in: ${CONFIG_FILE}"
if [[ "$CLOUD" == "azure" || "$CLOUD" == "gcp" || "$CLOUD" == "aws" ]]; then
echo "  2. Create DB users (run once after first apply):"
echo "       kubectl run pg-init --rm -it --image=postgres:16 -- psql -h <pg_host> -U pgadmin -c \\"
echo "         \"CREATE USER keycloak WITH PASSWORD '<pg_keycloak_password>';\""
echo "       (repeat for gitlab user; passwords from: tofu output -json)"
fi
if [[ "$CLOUD" == "gcp" ]]; then
echo "  3. Fill in Google OAuth credentials: ${SCRIPT_DIR}/${ENV}/gcp-idp.env"
fi
if [[ "$CLOUD" == "aws" ]]; then
echo "  3. Cognito IdP credentials written to: ${SCRIPT_DIR}/${ENV}/aws-idp.env"
fi
echo "  4. export KUBECONFIG=${KUBECONFIG_FILE}"
echo "  5. ./deploy.sh --env ${ENV}"
echo ""
