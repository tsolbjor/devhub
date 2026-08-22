#!/bin/bash
set -euo pipefail

# =============================================================================
# Environment Setup Wizard
# =============================================================================
# Prepares everything you must supply before `tofu init` can run:
#
#   tofu/<cloud>/<env>/backend.hcl       remote state location
#   tofu/<cloud>/<env>/terraform.tfvars  api_allowed_cidrs + per-cloud required vars
#   k8s/overlays/<env>/config.yaml       your domain and ACME email
#
# and, optionally, creates the state store itself (bucket/container + lock table),
# which is the one prerequisite that cannot come from tofu — tofu needs it to exist
# before it can hold state.
#
# Usage:
#   ./setup-env.sh --env aws-dev                    interactive
#   ./setup-env.sh --env aws-dev --dry-run          print what it would write
#   ./setup-env.sh --env aws-dev --non-interactive \
#       --domain dev.example.org --acme-email ops@example.org \
#       --api-cidrs 203.0.113.4/32 --state-bucket devhub-tfstate
#
# Existing files are never overwritten without --force.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ─── Arguments ────────────────────────────────────────────────────────

ENV=""
DOMAIN_IN=""
ACME_EMAIL_IN=""
PREFIX_IN=""
DEPLOYED_BY_IN=""
API_CIDRS_IN=""
STATE_BUCKET=""
STATE_KEY_PREFIX=""
LOCK_TABLE=""
REGION_IN=""
PROJECT_IN=""
AAD_GROUPS_IN=""
AZURE_STATE_RG=""
OBJSTO_ENDPOINT=""
MIRROR_URL_IN=""
MIRROR_TOKEN_IN=""
CREATE_STORE=""
INTERACTIVE=true
DRY_RUN=false
FORCE=false
ASSUME_YES=false

usage() {
    cat <<EOF
Usage: $0 --env <environment> [options]

Options:
  --domain <fqdn>              platform domain (e.g. dev.example.org)
  --acme-email <address>       Let's Encrypt contact address
  --prefix <name>              deployment prefix: names every resource and the
                               globally-unique namespaces (buckets, SSO domain);
                               3-16 lowercase chars, one per deployment
  --deployed-by <identity>     who configured this deployment (tags only;
                               detected from the cloud CLI when omitted)
  --api-cidrs <a,b,...>        CIDRs allowed to reach the Kubernetes API
                               ("none" = private endpoint only)
  --state-bucket <name>        state bucket / storage account / container host
  --state-key-prefix <path>    key prefix inside the state store
  --lock-table <name>          AWS only: DynamoDB lock table
  --region <region>            AWS region / Azure location / GCP region
  --project <id>               GCP project id
  --aad-admin-groups <a,b>     Azure only: Entra group object ids for cluster-admin
  --objsto-endpoint <url>      UpCloud only: Managed Object Storage S3 endpoint
  --mirror-url <url>           off-cluster mirror for the GitOps repository
                               (e.g. https://github.com/acme/aws-dev.git)
  --mirror-token <token>       write token for that mirror
  --create-state-store         create the bucket/container (and lock table)
  --no-create-state-store      skip creating it
  --non-interactive            never prompt; fail if a required value is missing
  --dry-run                   print the files instead of writing them
  --force                      overwrite existing backend.hcl / terraform.tfvars
  --yes                        assume yes for confirmations
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)                   ENV="${2:-}"; shift 2 ;;
        --domain)                DOMAIN_IN="${2:-}"; shift 2 ;;
        --acme-email)            ACME_EMAIL_IN="${2:-}"; shift 2 ;;
        --prefix)                PREFIX_IN="${2:-}"; shift 2 ;;
        --deployed-by)           DEPLOYED_BY_IN="${2:-}"; shift 2 ;;
        --api-cidrs)             API_CIDRS_IN="${2:-}"; shift 2 ;;
        --state-bucket)          STATE_BUCKET="${2:-}"; shift 2 ;;
        --state-key-prefix)      STATE_KEY_PREFIX="${2:-}"; shift 2 ;;
        --lock-table)            LOCK_TABLE="${2:-}"; shift 2 ;;
        --region)                REGION_IN="${2:-}"; shift 2 ;;
        --project)               PROJECT_IN="${2:-}"; shift 2 ;;
        --aad-admin-groups)      AAD_GROUPS_IN="${2:-}"; shift 2 ;;
        --objsto-endpoint)       OBJSTO_ENDPOINT="${2:-}"; shift 2 ;;
        --mirror-url)            MIRROR_URL_IN="${2:-}"; shift 2 ;;
        --mirror-token)          MIRROR_TOKEN_IN="${2:-}"; shift 2 ;;
        --create-state-store)    CREATE_STORE=true; shift ;;
        --no-create-state-store) CREATE_STORE=false; shift ;;
        --non-interactive)       INTERACTIVE=false; shift ;;
        --dry-run)               DRY_RUN=true; shift ;;
        --force)                 FORCE=true; shift ;;
        --yes|-y)                ASSUME_YES=true; shift ;;
        -h|--help)               usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

[[ -n "$ENV" ]] || { log_error "Missing --env"; usage; exit 1; }

if [[ " ${PLATFORM_ENVS} ${WORKLOAD_ENVS} " != *" ${ENV} "* ]]; then
    log_error "Unknown environment: ${ENV}"
    log_error "  Platform: ${PLATFORM_ENVS}"
    log_error "  Workload: ${WORKLOAD_ENVS}"
    exit 1
fi

if [[ "$ENV" == "local" ]]; then
    log_error "The local environment needs none of this — it has no infrastructure layer."
    log_error "Run: ./devhub bootstrap --env local"
    exit 1
fi

CLOUD="${ENV%%-*}"
case "$ENV" in
    *-workload) TIER="workload" ;;
    *-dev)      TIER="dev" ;;
    *-prod)     TIER="prod" ;;
esac

TOFU_DIR="${REPO_ROOT}/tofu/${CLOUD}/${TIER}"
CONFIG_FILE="${REPO_ROOT}/k8s/overlays/${ENV}/config.yaml"
BACKEND_FILE="${TOFU_DIR}/backend.hcl"
TFVARS_FILE="${TOFU_DIR}/terraform.tfvars"
MANUAL_SECRETS_FILE="${SCRIPT_DIR}/${ENV}/manual-secrets.env"

[[ -d "$TOFU_DIR" ]]    || { log_error "No tofu module at ${TOFU_DIR}"; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { log_error "No overlay config at ${CONFIG_FILE}"; exit 1; }

# ─── Prompt helpers ───────────────────────────────────────────────────

# ask <variable-name> <prompt> [default]
# Uses the pre-set value when there is one, prompts when interactive, and fails in
# non-interactive mode if there is nothing to use.
ask() {
    local var="$1" prompt="$2" default="${3:-}" current answer
    current="${!var:-}"

    if [[ -n "$current" ]]; then
        echo "  ${prompt}: ${current}"
        return 0
    fi

    if ! $INTERACTIVE; then
        if [[ -n "$default" ]]; then
            printf -v "$var" '%s' "$default"
            echo "  ${prompt}: ${default} (default)"
            return 0
        fi
        log_error "--non-interactive: no value for '${prompt}'"
        exit 1
    fi

    if [[ -n "$default" ]]; then
        read -r -p "  ${prompt} [${default}]: " answer
        answer="${answer:-$default}"
    else
        read -r -p "  ${prompt}: " answer
    fi
    printf -v "$var" '%s' "$answer"
}

confirm() {
    local prompt="$1" answer
    $ASSUME_YES && return 0
    $INTERACTIVE || return 1
    read -r -p "  ${prompt} [y/N]: " answer
    [[ "$answer" =~ ^[Yy] ]]
}

# Current public egress address — the usual answer to "which CIDR should reach the
# API server". Best-effort; no failure if there is no network.
detect_public_ip() {
    curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true
}

# The identity behind the cloud CLI — the best answer to "who set this
# environment up". Best-effort; falls back to user@host.
detect_deployer() {
    local who=""
    case "$CLOUD" in
        aws)     who="$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || true)" ;;
        azure)   who="$(az account show --query 'user.name' -o tsv 2>/dev/null || true)" ;;
        gcp)     who="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1 || true)" ;;
        upcloud) who="${UPCLOUD_USERNAME:-}" ;;
    esac
    [[ -n "$who" ]] && echo "$who" || echo "${USER:-unknown}@$(hostname 2>/dev/null || echo unknown)"
}

# ─── Read back an existing configuration ──────────────────────────────
#
# Re-running with --force must prefill what is already configured, otherwise
# "change one setting" means retyping all of them (and risking a silent change to
# the state bucket, which would orphan the existing state).

hcl_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -1
}

load_existing() {
    [[ -f "$BACKEND_FILE" ]] || [[ -f "$TFVARS_FILE" ]] || return 0

    log_info "Existing configuration found — values below are prefilled from it"

    case "$CLOUD" in
        aws)
            STATE_BUCKET="${STATE_BUCKET:-$(hcl_value "$BACKEND_FILE" bucket)}"
            LOCK_TABLE="${LOCK_TABLE:-$(hcl_value "$BACKEND_FILE" dynamodb_table)}"
            REGION_IN="${REGION_IN:-$(hcl_value "$BACKEND_FILE" region)}"
            ;;
        azure)
            STATE_BUCKET="${STATE_BUCKET:-$(hcl_value "$BACKEND_FILE" storage_account_name)}"
            AZURE_STATE_RG="${AZURE_STATE_RG:-$(hcl_value "$BACKEND_FILE" resource_group_name)}"
            ;;
        gcp)
            STATE_BUCKET="${STATE_BUCKET:-$(hcl_value "$BACKEND_FILE" bucket)}"
            PROJECT_IN="${PROJECT_IN:-$(hcl_value "$TFVARS_FILE" project_id)}"
            REGION_IN="${REGION_IN:-$(hcl_value "$TFVARS_FILE" region)}"
            ;;
        upcloud)
            STATE_BUCKET="${STATE_BUCKET:-$(hcl_value "$BACKEND_FILE" bucket)}"
            REGION_IN="${REGION_IN:-$(hcl_value "$BACKEND_FILE" region)}"
            OBJSTO_ENDPOINT="${OBJSTO_ENDPOINT:-$(hcl_value "$BACKEND_FILE" s3)}"
            ;;
    esac

    # api_allowed_cidrs = ["a", "b"]  →  a,b   (and [] → none)
    if [[ -z "$API_CIDRS_IN" && -f "$TFVARS_FILE" ]]; then
        local raw
        raw="$(sed -n 's/^[[:space:]]*api_allowed_cidrs[[:space:]]*=[[:space:]]*\[\(.*\)\].*/\1/p' "$TFVARS_FILE" | head -1)"
        if [[ -n "$raw" ]]; then
            API_CIDRS_IN="$(echo "$raw" | tr -d '" ' )"
        elif grep -qE '^[[:space:]]*api_allowed_cidrs[[:space:]]*=[[:space:]]*\[\][[:space:]]*$' "$TFVARS_FILE"; then
            API_CIDRS_IN="none"
        fi
    fi

    if [[ -z "$AAD_GROUPS_IN" && "$CLOUD" == "azure" && -f "$TFVARS_FILE" ]]; then
        local groups
        groups="$(sed -n 's/^[[:space:]]*aad_admin_group_object_ids[[:space:]]*=[[:space:]]*\[\(.*\)\].*/\1/p' "$TFVARS_FILE" | head -1)"
        [[ -n "$groups" ]] && AAD_GROUPS_IN="$(echo "$groups" | tr -d '" ')"
    fi

    PREFIX_IN="${PREFIX_IN:-$(hcl_value "$TFVARS_FILE" prefix)}"
    DEPLOYED_BY_IN="${DEPLOYED_BY_IN:-$(hcl_value "$TFVARS_FILE" deployed_by)}"
}

# ─── Gather values ────────────────────────────────────────────────────

echo ""
log_phase "Environment setup: ${ENV} (${CLOUD} / ${TIER})"

if [[ -f "$BACKEND_FILE" || -f "$TFVARS_FILE" ]] && ( $FORCE || $DRY_RUN ); then
    load_existing
fi

if [[ -f "$BACKEND_FILE" || -f "$TFVARS_FILE" ]] && ! $FORCE && ! $DRY_RUN; then
    log_error "Already configured:"
    [[ -f "$BACKEND_FILE" ]] && log_error "  ${BACKEND_FILE#"${REPO_ROOT}/"}"
    [[ -f "$TFVARS_FILE" ]]  && log_error "  ${TFVARS_FILE#"${REPO_ROOT}/"}"
    log_error "Re-run with --force to overwrite, or --dry-run to see what would change."
    exit 1
fi

# ── Platform domain (workload clusters get their own subdomain) ───────
echo ""
echo "Domain and TLS"
CURRENT_DOMAIN="$(yaml_get "$CONFIG_FILE" domain)"
[[ "$CURRENT_DOMAIN" == *example.com ]] && CURRENT_DOMAIN=""
DOMAIN_IN="${DOMAIN_IN:-$CURRENT_DOMAIN}"
ask DOMAIN_IN "Domain for this environment (DNS you control)"
[[ -n "$DOMAIN_IN" ]] || { log_error "A domain is required"; exit 1; }

CURRENT_EMAIL="$(yaml_get "$CONFIG_FILE" acmeEmail)"
[[ "$CURRENT_EMAIL" == *example.com ]] && CURRENT_EMAIL=""
ACME_EMAIL_IN="${ACME_EMAIL_IN:-$CURRENT_EMAIL}"
ask ACME_EMAIL_IN "ACME contact email (expiry notices)" "admin@${DOMAIN_IN}"

# ── Off-cluster mirror for the GitOps repository ──────────────────────
#
# The GitOps repository is hosted by the Forgejo running on this very cluster,
# which is what self-hosted means and is fine in normal operation. It does mean
# the repository describing the cluster dies with the cluster, so a copy
# elsewhere is the difference between rebuilding and reconstructing. Forgejo
# pushes to it on every commit; setup-gitops-repo.sh wires that up from here.
#
# Optional on purpose: an environment with no external git host is a legitimate
# choice, and Velero still backs up Forgejo's volume.
echo ""
echo "Off-cluster mirror for the GitOps repository (optional)"
if [[ -z "$MIRROR_URL_IN" ]] && $INTERACTIVE; then
    echo "  The GitOps repository lives in this environment's own Forgejo."
    echo "  A mirror elsewhere is what survives losing the cluster."
    read -r -p "  Mirror repository URL (blank to skip): " MIRROR_URL_IN
fi

if [[ -n "$MIRROR_URL_IN" && -z "$MIRROR_TOKEN_IN" ]] && $INTERACTIVE; then
    # -s: a write token must not land in scrollback or shell history.
    read -r -s -p "  Write token for ${MIRROR_URL_IN}: " MIRROR_TOKEN_IN
    echo ""
fi

# ── API server exposure ───────────────────────────────────────────────
echo ""
echo "Kubernetes API exposure"
if [[ -z "$API_CIDRS_IN" ]]; then
    if $INTERACTIVE; then
        MY_IP="$(detect_public_ip)"
        echo "  Who may reach the API server?"
        [[ -n "$MY_IP" ]] && echo "    1) this machine only  (${MY_IP}/32)"
        echo "    2) specific CIDRs"
        echo "    3) no public endpoint  (private only — needs VPN/bastion access)"
        read -r -p "  Choice [1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            1)
                if [[ -n "$MY_IP" ]]; then
                    API_CIDRS_IN="${MY_IP}/32"
                else
                    log_warn "Could not detect a public IP — enter CIDRs manually"
                    read -r -p "  CIDRs (comma separated): " API_CIDRS_IN
                fi
                ;;
            2) read -r -p "  CIDRs (comma separated): " API_CIDRS_IN ;;
            3) API_CIDRS_IN="none" ;;
            *) log_error "Invalid choice"; exit 1 ;;
        esac
    else
        log_error "--non-interactive: --api-cidrs is required (use 'none' for private-only)"
        exit 1
    fi
fi

# Render the tfvars list form.
if [[ "$API_CIDRS_IN" == "none" || "$API_CIDRS_IN" == "[]" ]]; then
    API_CIDRS_HCL="[]"
    log_info "API server will have no public endpoint"
else
    API_CIDRS_HCL="[$(echo "$API_CIDRS_IN" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | awk 'NF {printf "%s\"%s\"", sep, $0; sep=", "}')]"
    if [[ "$API_CIDRS_IN" == *"0.0.0.0/0"* ]]; then
        log_warn "0.0.0.0/0 exposes the control plane to the whole internet."
        confirm "Continue anyway?" || exit 1
    fi
fi

# ── Deployment identity ───────────────────────────────────────────────
#
# The prefix names every resource tofu creates, including names that are
# globally unique across the provider (buckets, the Cognito domain, Azure
# storage accounts). Two deployments must never share one, so the default
# only suits the first deployment in an organization.
echo ""
echo "Deployment identity"
echo "  The prefix names every cloud resource, including globally-unique ones"
echo "  (buckets, SSO domain). Use one per deployment, e.g. <org>-${TIER}."
ask PREFIX_IN "Deployment prefix" "devhub-${TIER}"
if ! [[ "$PREFIX_IN" =~ ^[a-z][a-z0-9-]{1,14}[a-z0-9]$ ]]; then
    log_error "Prefix must be 3-16 lowercase letters, digits or dashes,"
    log_error "starting with a letter and not ending in a dash: ${PREFIX_IN}"
    exit 1
fi
if [[ "$CLOUD" == "aws" && "$PREFIX_IN" =~ (aws|amazon|cognito) ]]; then
    log_error "Prefix must not contain 'aws', 'amazon' or 'cognito' —"
    log_error "Cognito rejects hosted-UI domains containing them: ${PREFIX_IN}"
    exit 1
fi

# Recorded as a tag on every resource; the cloud CLI knows who is running this.
ask DEPLOYED_BY_IN "Deployed by (identity written to resource tags)" "$(detect_deployer)"

# ── Per-cloud values ──────────────────────────────────────────────────
echo ""
echo "State storage and cloud settings"

# State-store names derive from the deployment prefix with the tier stripped,
# so dev and prod of one deployment share a store (the key prefix separates
# them) while two deployments never collide on the globally-unique names —
# a constant default here is how "devhubtfstate" ends up owned by a stranger
# and tofu init dies with a cross-tenant 401.
state_base() {
    echo "${PREFIX_IN%-${TIER}}"
}

default_bucket() {
    case "$CLOUD" in
        azure) local base; base="$(state_base)"; echo "${base//-/}tfstate" ;;   # storage account: lowercase alphanumeric, <=24
        *)     echo "$(state_base)-tfstate" ;;
    esac
}

case "$CLOUD" in
    aws)
        ask REGION_IN "AWS region" "eu-west-1"
        ask STATE_BUCKET "S3 bucket for tofu state" "$(default_bucket)"
        ask LOCK_TABLE "DynamoDB table for state locking" "$(state_base)-tfstate-lock"
        STATE_KEY_PREFIX="${STATE_KEY_PREFIX:-aws/${TIER}}"
        ;;
    azure)
        ask REGION_IN "Azure location" "westeurope"
        ask STATE_BUCKET "Storage account for tofu state" "$(default_bucket)"
        ask AZURE_STATE_RG "Resource group for the state account" "$(state_base)-tfstate-rg"
        ask AAD_GROUPS_IN "Entra group object ids for cluster-admin (comma separated, empty to skip)" " "
        STATE_KEY_PREFIX="${STATE_KEY_PREFIX:-azure-${TIER}}"
        ;;
    gcp)
        ask PROJECT_IN "GCP project id"
        ask REGION_IN "GCP region" "europe-west4"
        ask STATE_BUCKET "GCS bucket for tofu state" "$(default_bucket)"
        STATE_KEY_PREFIX="${STATE_KEY_PREFIX:-gcp/${TIER}}"
        ;;
    upcloud)
        ask REGION_IN "Object storage region" "europe-1"
        ask OBJSTO_ENDPOINT "Managed Object Storage endpoint (https://<id>.upcloudobjects.com)"
        ask STATE_BUCKET "Bucket for tofu state" "devhub-tfstate"
        STATE_KEY_PREFIX="${STATE_KEY_PREFIX:-upcloud/${TIER}}"
        ;;
esac

# ─── Render files ─────────────────────────────────────────────────────

render_backend() {
    case "$CLOUD" in
        aws)
            cat <<EOF
# Generated by setup-env.sh for ${ENV}. Not committed (gitignored).
bucket         = "${STATE_BUCKET}"
key            = "${STATE_KEY_PREFIX}/terraform.tfstate"
region         = "${REGION_IN}"
dynamodb_table = "${LOCK_TABLE}"
encrypt        = true
EOF
            ;;
        azure)
            cat <<EOF
# Generated by setup-env.sh for ${ENV}. Not committed (gitignored).
resource_group_name  = "${AZURE_STATE_RG}"
storage_account_name = "${STATE_BUCKET}"
container_name       = "tfstate"
key                  = "${STATE_KEY_PREFIX}.terraform.tfstate"
use_azuread_auth     = true
EOF
            ;;
        gcp)
            cat <<EOF
# Generated by setup-env.sh for ${ENV}. Not committed (gitignored).
bucket = "${STATE_BUCKET}"
prefix = "${STATE_KEY_PREFIX}"
EOF
            ;;
        upcloud)
            cat <<EOF
# Generated by setup-env.sh for ${ENV}. Not committed (gitignored).
#
# UpCloud has no native OpenTofu backend; its Managed Object Storage is
# S3-compatible, so AWS-only behaviours are switched off below. Credentials come
# from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY set to the object storage user's
# access key.
bucket = "${STATE_BUCKET}"
key    = "${STATE_KEY_PREFIX}/terraform.tfstate"
region = "${REGION_IN}"

endpoints = {
  s3 = "${OBJSTO_ENDPOINT}"
}

skip_credentials_validation = true
skip_region_validation      = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_s3_checksum            = true
use_path_style              = true
use_lockfile                = true
EOF
            ;;
    esac
}

render_tfvars() {
    echo "# Generated by setup-env.sh for ${ENV}. Not committed (gitignored)."
    echo ""
    echo "# Deployment identity — names every resource; unique per deployment."
    echo "prefix      = \"${PREFIX_IN}\""
    echo "# Who configured this deployment (resource tags only)."
    echo "deployed_by = \"${DEPLOYED_BY_IN}\""
    echo ""
    echo "# CIDRs allowed to reach the Kubernetes API server ([] = private endpoint only)."
    echo "api_allowed_cidrs = ${API_CIDRS_HCL}"

    case "$CLOUD" in
        aws)
            echo ""
            echo "region = \"${REGION_IN}\""
            ;;
        gcp)
            echo ""
            echo "project_id = \"${PROJECT_IN}\""
            echo "region     = \"${REGION_IN}\""
            ;;
        azure)
            local groups
            groups="$(echo "${AAD_GROUPS_IN:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
                | awk 'NF {printf "%s\"%s\"", sep, $0; sep=", "}')"
            echo ""
            if [[ -n "$groups" ]]; then
                echo "# Setting this enables Azure RBAC and disables the AKS local admin account."
                echo "aad_admin_group_object_ids = [${groups}]"
            else
                echo "# Set this to enable Azure RBAC and disable the AKS local admin account"
                echo "# (a permanent cluster-admin certificate that cannot be attributed to a person):"
                echo "# aad_admin_group_object_ids = [\"00000000-0000-0000-0000-000000000000\"]"
                echo "aad_admin_group_object_ids = []"
            fi
            ;;
    esac
}

echo ""
log_step "backend.hcl → ${BACKEND_FILE#"${REPO_ROOT}/"}"
render_backend | sed 's/^/    /'
echo ""
log_step "terraform.tfvars → ${TFVARS_FILE#"${REPO_ROOT}/"}"
render_tfvars | sed 's/^/    /'
echo ""
log_step "config.yaml → ${CONFIG_FILE#"${REPO_ROOT}/"}"
echo "    domain: ${DOMAIN_IN}"
echo "    acmeEmail: ${ACME_EMAIL_IN}"
if [[ "$TIER" == "workload" ]]; then
    echo "    platformVaultUrl / platformLokiUrl: derived from the platform domain (edit if it differs)"
fi
echo ""

if [[ -n "$MIRROR_URL_IN" && -n "$MIRROR_TOKEN_IN" ]]; then
    echo "[STEP] manual-secrets.env → ${MANUAL_SECRETS_FILE#"${REPO_ROOT}/"}"
    echo "    GITOPS_MIRROR_URL=${MIRROR_URL_IN}"
    echo "    GITOPS_MIRROR_TOKEN=<hidden>"
    echo ""
fi

if $DRY_RUN; then
    log_info "--dry-run: nothing written"
    exit 0
fi

confirm "Write these files?" || { log_warn "Aborted — nothing written"; exit 1; }

umask 077
render_backend > "$BACKEND_FILE"
render_tfvars  > "$TFVARS_FILE"
log_info "Wrote ${BACKEND_FILE#"${REPO_ROOT}/"}"
log_info "Wrote ${TFVARS_FILE#"${REPO_ROOT}/"}"

# config.yaml is a committed, human-owned file: only the values just confirmed are
# touched, in place, with the surrounding comments left alone.
update_config() {
    local file="$1" domain="$2" email="$3" tier="$4"
    python3 - "$file" "$domain" "$email" "$tier" <<'PY'
import re, sys

path, domain, email, tier = sys.argv[1:5]
text = open(path).read()

text = re.sub(r'^domain:.*$', f'domain: {domain}', text, count=1, flags=re.M)
text = re.sub(r'^acmeEmail:.*$', f'acmeEmail: {email}', text, count=1, flags=re.M)

# GitOps repo URL follows the platform's own Forgejo instance.
text = re.sub(r'^(\s*repoUrl:).*$', rf'\1 https://git.{domain}/devhub/devhub.git',
              text, count=1, flags=re.M)

# Workload clusters point at the platform cluster; strip the leading app subdomain
# to guess it, which is right for the documented apps.<domain> layout.
if tier == 'workload':
    platform_domain = domain.split('.', 1)[1] if domain.count('.') > 1 else domain
    text = re.sub(r'^platformVaultUrl:.*$', f'platformVaultUrl: https://vault.{platform_domain}',
                  text, count=1, flags=re.M)
    text = re.sub(r'^platformLokiUrl:.*$', f'platformLokiUrl: https://loki.{platform_domain}',
                  text, count=1, flags=re.M)

open(path, 'w').write(text)
PY
}

if command -v python3 &>/dev/null; then
    update_config "$CONFIG_FILE" "$DOMAIN_IN" "$ACME_EMAIL_IN" "$TIER"
    log_info "Updated ${CONFIG_FILE#"${REPO_ROOT}/"} (domain, acmeEmail, gitops.repoUrl)"
else
    log_warn "python3 not found — set domain and acmeEmail in ${CONFIG_FILE#"${REPO_ROOT}/"} by hand"
fi

# Mirror credentials: gitignored, 0600, alongside the other values tofu cannot
# produce. setup-gitops-repo.sh reads them when it publishes the repository.
if [[ -n "$MIRROR_URL_IN" && -n "$MIRROR_TOKEN_IN" ]]; then
    mkdir -p "$(dirname "$MANUAL_SECRETS_FILE")"
    touch "$MANUAL_SECRETS_FILE"
    chmod 600 "$MANUAL_SECRETS_FILE"
    # Replace previous values rather than appending a second definition, which
    # would silently win or lose depending on source order.
    grep -v -E '^GITOPS_MIRROR_(URL|TOKEN|USER)=' "$MANUAL_SECRETS_FILE" \
        > "${MANUAL_SECRETS_FILE}.tmp" 2>/dev/null || true
    mv "${MANUAL_SECRETS_FILE}.tmp" "$MANUAL_SECRETS_FILE"
    {
        echo "GITOPS_MIRROR_URL=${MIRROR_URL_IN}"
        echo "GITOPS_MIRROR_TOKEN=${MIRROR_TOKEN_IN}"
    } >> "$MANUAL_SECRETS_FILE"
    chmod 600 "$MANUAL_SECRETS_FILE"
    log_info "Mirror credentials → ${MANUAL_SECRETS_FILE#"${REPO_ROOT}/"}"
elif [[ -n "$MIRROR_URL_IN" ]]; then
    log_warn "Mirror URL given without a token — skipped. Add both to"
    log_warn "  ${MANUAL_SECRETS_FILE#"${REPO_ROOT}/"}"
else
    log_info "No off-cluster mirror: the GitOps repository will exist only in this cluster"
fi


# ─── Optionally create the state store ────────────────────────────────
#
# tofu cannot create its own backend, so this is the one piece of infrastructure
# that has to exist beforehand.

state_store_exists() {
    case "$CLOUD" in
        aws)     aws s3api head-bucket --bucket "$STATE_BUCKET" &>/dev/null ;;
        azure)   az storage account show -n "$STATE_BUCKET" -g "$AZURE_STATE_RG" &>/dev/null ;;
        gcp)     gcloud storage buckets describe "gs://${STATE_BUCKET}" &>/dev/null ;;
        upcloud) return 1 ;;  # no API check; the user provides an existing bucket
    esac
}

create_state_store() {
    case "$CLOUD" in
        aws)
            command -v aws &>/dev/null || { log_error "aws CLI not found"; return 1; }
            log_step "Creating S3 bucket ${STATE_BUCKET} (${REGION_IN})..."
            if [[ "$REGION_IN" == "us-east-1" ]]; then
                aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION_IN"
            else
                aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION_IN" \
                    --create-bucket-configuration "LocationConstraint=${REGION_IN}"
            fi
            aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
                --versioning-configuration Status=Enabled
            aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" \
                --server-side-encryption-configuration \
                '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
            aws s3api put-public-access-block --bucket "$STATE_BUCKET" \
                --public-access-block-configuration \
                'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

            log_step "Creating DynamoDB lock table ${LOCK_TABLE}..."
            aws dynamodb create-table --table-name "$LOCK_TABLE" \
                --attribute-definitions AttributeName=LockID,AttributeType=S \
                --key-schema AttributeName=LockID,KeyType=HASH \
                --billing-mode PAY_PER_REQUEST \
                --region "$REGION_IN" >/dev/null
            ;;
        azure)
            command -v az &>/dev/null || { log_error "az CLI not found"; return 1; }
            if [[ "$(az group exists -n "$AZURE_STATE_RG" 2>/dev/null)" != "true" ]]; then
                log_step "Creating resource group ${AZURE_STATE_RG}..."
                az group create -n "$AZURE_STATE_RG" -l "$REGION_IN" >/dev/null || return 1
            fi
            log_step "Creating storage account ${STATE_BUCKET}..."
            az storage account create -n "$STATE_BUCKET" -g "$AZURE_STATE_RG" -l "$REGION_IN" \
                --sku Standard_LRS --encryption-services blob --min-tls-version TLS1_2 \
                --allow-blob-public-access false >/dev/null || return 1

            # The backend uses use_azuread_auth, and Owner/Contributor on the
            # subscription carries no data-plane rights — without this role,
            # both the container create below and every tofu init get a 403
            # AuthorizationPermissionMismatch.
            log_step "Granting yourself 'Storage Blob Data Contributor' on ${STATE_BUCKET}..."
            local scope me
            scope="$(az storage account show -n "$STATE_BUCKET" -g "$AZURE_STATE_RG" --query id -o tsv)"
            me="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
            if [[ -n "$me" && -n "$scope" ]] && az role assignment create \
                    --assignee-object-id "$me" --assignee-principal-type User \
                    --role "Storage Blob Data Contributor" --scope "$scope" >/dev/null; then
                : # role granted; propagation can still take a minute
            else
                log_warn "Could not grant the role (service principal login, or no rights to assign roles)."
                log_warn "Grant it before 'init', or tofu cannot reach the state:"
                log_warn "  az role assignment create --assignee <you> --role 'Storage Blob Data Contributor' --scope ${scope:-<account-id>}"
            fi

            log_step "Creating container tfstate..."
            # Data-plane RBAC propagates asynchronously; retry briefly before giving up.
            local attempt
            for attempt in 1 2 3 4 5; do
                az storage container create -n tfstate --account-name "$STATE_BUCKET" \
                    --auth-mode login >/dev/null 2>&1 && break
                [[ "$attempt" == 5 ]] && { log_error "Could not create the tfstate container"; return 1; }
                sleep 10
            done
            ;;
        gcp)
            command -v gcloud &>/dev/null || { log_error "gcloud not found"; return 1; }
            log_step "Creating GCS bucket ${STATE_BUCKET}..."
            gcloud storage buckets create "gs://${STATE_BUCKET}" \
                --project "$PROJECT_IN" --location "$REGION_IN" --uniform-bucket-level-access
            gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
            ;;
        upcloud)
            log_warn "UpCloud Managed Object Storage must be created in the console or with upctl:"
            log_warn "  upctl object-storage create --name devhub-tfstate --region ${REGION_IN} ..."
            log_warn "Then create bucket '${STATE_BUCKET}' and a user access key, and export:"
            log_warn "  AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"
            return 1
            ;;
    esac
}

echo ""
if [[ "$CLOUD" == "upcloud" ]]; then
    log_info "Assuming the object storage bucket already exists (UpCloud has no create step here)."
elif state_store_exists; then
    log_info "State store already exists: ${STATE_BUCKET}"
else
    log_warn "State store ${STATE_BUCKET} does not exist yet. tofu cannot create its own backend."
    if [[ "${CREATE_STORE:-}" == "true" ]] || { [[ -z "${CREATE_STORE:-}" ]] && confirm "Create it now?"; }; then
        if create_state_store; then
            log_info "State store ready"
        else
            log_error "Could not create the state store — create it manually, then re-run ./devhub init"
        fi
    else
        log_warn "Skipped. Create it before running ./devhub init --env ${ENV}"
    fi
fi

# ─── Next steps ───────────────────────────────────────────────────────

echo ""
log_info "Setup complete for ${ENV}"
echo ""
echo "  Next:"
echo "    ./devhub init  --env ${ENV}"
echo "    ./devhub plan  --env ${ENV}"
echo "    ./devhub apply --env ${ENV}"
if [[ "$TIER" == "workload" ]]; then
    echo "    ./devhub deploy   --env ${ENV}"
    echo "    ./devhub register --env ${ENV}"
else
    echo "    ./devhub bootstrap --env ${ENV}"
fi
echo ""
echo "  DNS: *.${DOMAIN_IN} must point at the ingress LoadBalancer once it exists"
echo "       (bootstrap prints the address when it finishes)."
echo ""
