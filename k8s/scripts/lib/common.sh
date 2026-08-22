#!/bin/bash
# =============================================================================
# Shared Library for Kubernetes Platform Scripts
# =============================================================================
# Source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib/common.sh"
#
# Configuration model
# -------------------
#   overlays/<env>/config.yaml       human-owned, committed: domain, TLS, toggles
#   scripts/<env>/tofu-outputs.env   machine-owned, gitignored: everything tofu knows
#
# sync-tofu-outputs.sh writes the second file; nothing rewrites the first. That
# keeps infrastructure values out of git diffs and removes the fragile
# `sed -i` / `grep -A1` round-trip that used to sit between tofu and Helm.
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_phase() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  PHASE: $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

PLATFORM_ENVS="local upcloud-dev upcloud-prod azure-dev azure-prod gcp-dev gcp-prod aws-dev aws-prod"
WORKLOAD_ENVS="upcloud-workload azure-workload gcp-workload aws-workload"

# =============================================================================
# Argument Parsing
# =============================================================================

# Parse --env <environment> from arguments.
# Sets ENV global and removes --env <val> from args.
# Remaining args are placed in ARGS array.
parse_env_arg() {
    ENV=""
    ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --env"
                    echo "Usage: $0 --env <environment> [...]"
                    exit 1
                fi
                ENV="$2"
                shift 2
                ;;
            *)
                ARGS+=("$1")
                shift
                ;;
        esac
    done

    if [[ -z "$ENV" ]]; then
        log_error "Missing required --env argument"
        echo "Usage: $0 --env <environment> [...]"
        exit 1
    fi

    if [[ " ${PLATFORM_ENVS} ${WORKLOAD_ENVS} " != *" ${ENV} "* ]]; then
        log_error "Invalid environment: $ENV"
        log_error "Platform environments: ${PLATFORM_ENVS}"
        log_error "Workload environments: ${WORKLOAD_ENVS}"
        exit 1
    fi

    export ENV
}

# True when $ENV is a workload cluster environment.
is_workload_env() {
    [[ " ${WORKLOAD_ENVS} " == *" ${ENV} "* ]]
}

# Cloud name derived from the environment (local, aws, azure, gcp, upcloud).
env_cloud() {
    case "$ENV" in
        local) echo "local" ;;
        *) echo "${ENV%%-*}" ;;
    esac
}

# =============================================================================
# YAML reading
# =============================================================================

# Read a scalar from a YAML file by dotted path: yaml_get <file> a.b.c
#
# Indentation-aware, so it cannot pick up a same-named key from a different
# parent — the previous `grep -A1 'redis:' | grep host:` approach silently
# returned the wrong value whenever keys were reordered. Handles scalars only
# (no sequences), which is all config.yaml holds. Inline comments and
# surrounding quotes are stripped; a missing path yields an empty string.
yaml_get() {
    local file="$1" path="$2"
    [[ -f "$file" ]] || return 0

    awk -v want="$path" '
        # strip trailing comments outside quotes (config.yaml has no # in values)
        {
            line = $0
            sub(/[[:space:]]*#.*$/, "", line)
            if (line ~ /^[[:space:]]*$/) next

            # indentation width
            match(line, /^[ ]*/)
            indent = RLENGTH

            # key: value
            if (line !~ /^[ ]*[A-Za-z0-9_.-]+:/) next
            key = line
            sub(/^[ ]*/, "", key)
            val = key
            sub(/^[A-Za-z0-9_.-]+:[ ]*/, "", val)
            sub(/:.*$/, "", key)

            # pop deeper levels off the path stack
            while (depth > 0 && indents[depth] >= indent) depth--
            depth++
            indents[depth] = indent
            keys[depth] = key

            full = keys[1]
            for (i = 2; i <= depth; i++) full = full "." keys[i]

            if (full == want) {
                gsub(/^[ \t]+|[ \t]+$/, "", val)
                # strip one layer of matching quotes
                if (val ~ /^".*"$/) { sub(/^"/, "", val); sub(/"$/, "", val) }
                else if (val ~ /^'"'"'.*'"'"'$/) { sub(/^'"'"'/, "", val); sub(/'"'"'$/, "", val) }
                print val
                exit
            }
        }
    ' "$file"
}

# =============================================================================
# Configuration
# =============================================================================

# Layered config lookup: the environment's local answers file (written by
# setup-env.sh, gitignored under k8s/scripts/<env>/) wins; the committed
# overlay config.yaml is the fallback and doubles as the sample. This is what
# lets the wizard record your domain without ever editing a committed file.
cfg_get() {
    local key="$1" v=""
    v="$(yaml_get "${SCRIPT_DIR}/${ENV}/config.yaml" "$key")"
    if [[ -n "$v" ]]; then
        echo "$v"
    else
        yaml_get "${K8S_DIR}/overlays/${ENV}/config.yaml" "$key"
    fi
}

# Parse config (local answers over committed overlay, see cfg_get) and load
# tofu-outputs.env (generated).
#
# Exports, from config:
#   DOMAIN TLS_TYPE TLS_SECRET_NAME CLUSTER_ISSUER ACME_EMAIL DATA_SERVICES_TYPE
#   PLATFORM_VAULT_URL PLATFORM_LOKI_URL ALERT_SLACK_WEBHOOK_SECRET
# Exports, from tofu-outputs.env (cloud-dependent):
#   PG_HOST REDIS_HOST VALKEY_HOST S3_* AZURE_* GCS_* AWS_* LOKI_* VELERO_* VAULT_KMS_* ...
parse_config() {
    local config_file="${K8S_DIR}/overlays/${ENV}/config.yaml"
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    export DOMAIN=$(cfg_get domain)
    export TLS_TYPE=$(cfg_get tls.type)
    export TLS_SECRET_NAME=$(cfg_get tls.secretName)
    export CLUSTER_ISSUER=$(cfg_get tls.clusterIssuer)
    export ACME_EMAIL=$(cfg_get acmeEmail)
    export DATA_SERVICES_TYPE=$(cfg_get dataServices.type)
    export PLATFORM_VAULT_URL=$(cfg_get platformVaultUrl)
    export PLATFORM_LOKI_URL=$(cfg_get platformLokiUrl)
    export GITOPS_REPO_URL=$(cfg_get gitops.repoUrl)
    export GITOPS_REVISION=$(cfg_get gitops.targetRevision)

    # Defaults
    TLS_SECRET_NAME="${TLS_SECRET_NAME:-local-tls-secret}"
    ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"
    DATA_SERVICES_TYPE="${DATA_SERVICES_TYPE:-local}"
    GITOPS_REVISION="${GITOPS_REVISION:-HEAD}"

    # The URL ArgoCD clones from, which is not always the URL a human clones from.
    #
    # On local, gitops.repoUrl is https://git.localhost/... — reachable from the
    # workstation through the gateway, and unreachable from inside the cluster:
    # glibc answers *.localhost with 127.0.0.1 in getaddrinfo before /etc/hosts is
    # consulted, so a pod dials itself and a hostAlias cannot override it (the
    # same reason Keycloak's server-side endpoints use KEYCLOAK_INTERNAL_URL).
    # ArgoCD therefore addresses Forgejo by its Service, over plain HTTP inside
    # the cluster. Everywhere else the two URLs are identical.
    if [[ "$DOMAIN" == "localhost" || "$DOMAIN" == *.localhost ]]; then
        local repo_path="${GITOPS_REPO_URL#*://}"
        repo_path="${repo_path#*/}"
        export GITOPS_REPO_URL_INTERNAL="http://forgejo-http.forgejo.svc.cluster.local:3000/${repo_path}"
    else
        export GITOPS_REPO_URL_INTERNAL="$GITOPS_REPO_URL"
    fi

    load_tofu_outputs
    default_infra_vars
}

# Source the generated tofu output file, if present.
load_tofu_outputs() {
    local outputs_file="${SCRIPT_ENV_DIR}/tofu-outputs.env"

    if [[ -f "$outputs_file" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "$outputs_file"
        set +a
        log_info "Loaded tofu outputs from ${outputs_file}"
    elif [[ "$DATA_SERVICES_TYPE" == "managed" ]] || is_workload_env; then
        log_warn "No tofu outputs found at ${outputs_file}"
        log_warn "Run: ./sync-tofu-outputs.sh --env ${ENV}"
    fi
}

# Every variable referenced by template_values must exist (possibly empty) or
# envsubst leaves the literal ${VAR} in rendered Helm values.
default_infra_vars() {
    local v
    for v in \
        PG_HOST PG_PORT VALKEY_HOST REDIS_HOST REDIS_PORT REDIS_TLS_ENABLED \
        S3_ENDPOINT S3_REGION AWS_REGION \
        AZURE_STORAGE_ACCOUNT AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP AZURE_NODE_RESOURCE_GROUP \
        GCS_PROJECT_ID \
        EXTERNAL_DNS_IRSA_ROLE_ARN EXTERNAL_DNS_IDENTITY_CLIENT_ID EXTERNAL_DNS_GSA_EMAIL \
        LOKI_IRSA_ROLE_ARN LOKI_IDENTITY_CLIENT_ID LOKI_GSA_EMAIL LOKI_BUCKET LOKI_CONTAINER \
        VELERO_IRSA_ROLE_ARN VELERO_IDENTITY_CLIENT_ID VELERO_GSA_EMAIL VELERO_BUCKET VELERO_CONTAINER \
        CLUSTER_AUTOSCALER_IRSA_ROLE_ARN CLUSTER_NAME OIDC_ISSUER_URL \
        VAULT_KMS_KEY_ID VAULT_KMS_IRSA_ROLE_ARN VAULT_IDENTITY_CLIENT_ID \
        VAULT_KEY_VAULT_NAME VAULT_KEY_NAME VAULT_GSA_EMAIL \
        VAULT_KMS_REGION VAULT_KMS_KEY_RING VAULT_KMS_CRYPTO_KEY \
        ENTRA_TENANT_ID ENTRA_KEYCLOAK_CLIENT_ID \
        COGNITO_ISSUER_URL COGNITO_HOSTED_UI_DOMAIN COGNITO_CLIENT_ID GOOGLE_IDP_CLIENT_ID
    do
        export "${v}=${!v:-}"
    done

    # The local environment runs its own data services at fixed service names.
    if [[ "${DATA_SERVICES_TYPE:-local}" == "local" ]]; then
        export PG_HOST="${PG_HOST:-postgresql.data-services.svc.cluster.local}"
        export VALKEY_HOST="${VALKEY_HOST:-valkey.data-services.svc.cluster.local}"
        export REDIS_HOST="${REDIS_HOST:-$VALKEY_HOST}"
        export S3_ENDPOINT="${S3_ENDPOINT:-http://minio.data-services.svc.cluster.local:9000}"
    fi

    # Convenience defaults derived from other values.
    export PG_PORT="${PG_PORT:-5432}"
    export REDIS_PORT="${REDIS_PORT:-6379}"
    export PLATFORM_LOKI_URL="${PLATFORM_LOKI_URL:-}"
}

# =============================================================================
# Templating
# =============================================================================

# Per-run private directory for rendered values. Rendered files can contain
# hostnames and role ARNs, and predictable /tmp paths are trivially clobbered by
# other users on a shared machine.
#
# Created by setup_paths in the top-level shell — creating it lazily from inside a
# command substitution (get_values_args) meant the cleanup trap fired when that
# subshell exited, deleting the files before helm could read them.
init_render_dir() {
    [[ -n "${RENDER_DIR:-}" ]] && return 0
    RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devhub-render.XXXXXX")"
    chmod 700 "$RENDER_DIR"
    export RENDER_DIR
    trap 'rm -rf "${RENDER_DIR}"' EXIT
}

render_dir() {
    if [[ -z "${RENDER_DIR:-}" ]]; then
        log_error "render_dir called before setup_paths — no scratch directory"
        exit 1
    fi
    echo "$RENDER_DIR"
}

# Variables envsubst is allowed to substitute. The list is explicit so that
# ArgoCD's own `$oidc.keycloak.clientSecret` placeholders survive templating.
TEMPLATE_VARS='${DOMAIN} ${TLS_SECRET_NAME} ${CLUSTER_ISSUER} ${ACME_EMAIL}
${PG_HOST} ${PG_PORT} ${VALKEY_HOST} ${REDIS_HOST} ${REDIS_PORT} ${REDIS_TLS_ENABLED}
${S3_ENDPOINT} ${S3_REGION} ${AWS_REGION}
${AZURE_STORAGE_ACCOUNT} ${AZURE_SUBSCRIPTION_ID} ${AZURE_RESOURCE_GROUP} ${AZURE_NODE_RESOURCE_GROUP}
${GCS_PROJECT_ID}
${EXTERNAL_DNS_IRSA_ROLE_ARN} ${EXTERNAL_DNS_IDENTITY_CLIENT_ID} ${EXTERNAL_DNS_GSA_EMAIL}
${LOKI_IRSA_ROLE_ARN} ${LOKI_IDENTITY_CLIENT_ID} ${LOKI_GSA_EMAIL} ${LOKI_BUCKET} ${LOKI_CONTAINER}
${VELERO_IRSA_ROLE_ARN} ${VELERO_IDENTITY_CLIENT_ID} ${VELERO_GSA_EMAIL} ${VELERO_BUCKET} ${VELERO_CONTAINER}
${CLUSTER_AUTOSCALER_IRSA_ROLE_ARN} ${CLUSTER_NAME}
${VAULT_KMS_KEY_ID} ${VAULT_KMS_IRSA_ROLE_ARN} ${VAULT_IDENTITY_CLIENT_ID}
${VAULT_KEY_VAULT_NAME} ${VAULT_KEY_NAME} ${VAULT_GSA_EMAIL}
${VAULT_KMS_REGION} ${VAULT_KMS_KEY_RING} ${VAULT_KMS_CRYPTO_KEY}
${ENTRA_TENANT_ID} ${PLATFORM_LOKI_URL} ${PLATFORM_VAULT_URL}
${ENV} ${GITOPS_REPO_URL} ${GITOPS_REPO_URL_INTERNAL} ${GITOPS_REVISION}'

# Template a file with the allow-listed environment variables.
template_values() {
    local input="$1"
    local output="$2"
    envsubst "$TEMPLATE_VARS" < "$input" > "$output"
}

# Get Helm values args for a component (base + templated overlay).
# Usage: get_values_args <component>
get_values_args() {
    local component="$1"
    local base_values="${BASE_DIR}/devops/${component}/values.yaml"
    local overlay_values="${OVERLAY_DIR}/devops/${component}/values.yaml"
    local dir
    dir="$(render_dir)"

    local args=""

    if [[ -f "$base_values" ]]; then
        template_values "$base_values" "${dir}/${component}-base-values.yaml"
        args="-f ${dir}/${component}-base-values.yaml"
    fi

    if [[ -f "$overlay_values" ]]; then
        template_values "$overlay_values" "${dir}/${component}-overlay-values.yaml"
        args="$args -f ${dir}/${component}-overlay-values.yaml"
    fi

    echo "$args"
}

# =============================================================================
# Cluster safety
# =============================================================================

# Point kubectl/helm at the kubeconfig generated for $ENV, when one exists.
#
# Without this, a script inherits whatever context the shell happens to be on —
# which is how workload components end up installed on the platform cluster.
use_env_kubeconfig() {
    local kubeconfig="${SCRIPT_ENV_DIR}/kubeconfig"

    if [[ -f "$kubeconfig" ]]; then
        export KUBECONFIG="$kubeconfig"
        log_info "Using kubeconfig: ${kubeconfig}"
    elif [[ "$ENV" != "local" ]]; then
        log_warn "No kubeconfig at ${kubeconfig} — falling back to the current context:"
        log_warn "  $(kubectl config current-context 2>/dev/null || echo '<none>')"
        log_warn "Run ./sync-tofu-outputs.sh --env ${ENV} to fetch the right one."
    fi
}

# Refuse to continue if the active context does not look like the expected
# cluster. Matches on the tofu-reported cluster name when available.
require_cluster_match() {
    local expected="${1:-${CLUSTER_NAME:-}}"
    local context
    context="$(kubectl config current-context 2>/dev/null || echo '')"

    if [[ -z "$context" ]]; then
        log_error "No active kubectl context — cannot verify the target cluster"
        exit 1
    fi

    if [[ -z "$expected" ]]; then
        log_warn "Cluster name unknown (no tofu outputs); target context is: ${context}"
        return 0
    fi

    if [[ "$context" != *"$expected"* ]]; then
        log_error "Refusing to deploy: active context does not match ${ENV}"
        log_error "  expected cluster name to contain: ${expected}"
        log_error "  active context:                   ${context}"
        log_error "Fix with: export KUBECONFIG=${SCRIPT_ENV_DIR}/kubeconfig"
        exit 1
    fi

    log_info "Target cluster verified: ${context}"
}

# =============================================================================
# Helm Repos
# =============================================================================

add_helm_repos() {
    command -v helm &>/dev/null || { log_error "helm required"; exit 1; }

    log_step "Adding Helm repositories..."

    local -a repos=(
        "jetstack https://charts.jetstack.io"
        "hashicorp https://helm.releases.hashicorp.com"
        "external-secrets https://charts.external-secrets.io"
        "prometheus-community https://prometheus-community.github.io/helm-charts"
        "grafana https://grafana.github.io/helm-charts"
        "argo https://argoproj.github.io/argo-helm"
        "external-dns https://kubernetes-sigs.github.io/external-dns/"
        "headlamp https://kubernetes-sigs.github.io/headlamp/"
        "jameswynn https://jameswynn.github.io/helm-charts"
        "woodpecker https://woodpecker-ci.org/"
        "kyverno https://kyverno.github.io/kyverno"
        "stakater https://stakater.github.io/stakater-charts"
        "vmware-tanzu https://vmware-tanzu.github.io/helm-charts"
        "autoscaler https://kubernetes.github.io/autoscaler"
    )

    local -a names=()
    local entry
    for entry in "${repos[@]}"; do
        helm repo add ${entry} 2>/dev/null || true
        names+=("${entry%% *}")
    done

    # Only these repos, not `helm repo update` over everything: an unrelated dead
    # repo in the user's own helm config would otherwise fail the run.
    helm repo update "${names[@]}"
    # Forgejo and Envoy Gateway are OCI charts — no repo to add, pulled by URL.
    log_info "Helm repositories updated"
}

# =============================================================================
# Requirement Checks
# =============================================================================

check_requirements() {
    log_info "Checking requirements..."
    command -v kubectl &>/dev/null || { log_error "kubectl required"; exit 1; }
    command -v envsubst &>/dev/null || { log_error "envsubst required (install gettext)"; exit 1; }
    command -v jq &>/dev/null || { log_error "jq required"; exit 1; }
    kubectl cluster-info &>/dev/null || { log_error "Cannot connect to cluster"; exit 1; }

    if [[ -z "${DOMAIN:-}" ]]; then
        log_error "DOMAIN not set. Check config.yaml in overlay directory."
        exit 1
    fi

    if [[ "$DOMAIN" == *example.com ]]; then
        log_error "DOMAIN is still the placeholder '${DOMAIN}'"
        log_error "Run './devhub setup --env ${ENV}' (answers land in k8s/scripts/${ENV}/config.yaml),"
        log_error "or edit ${K8S_DIR}/overlays/${ENV}/config.yaml directly."
        exit 1
    fi

    if [[ "$ENV" == "local" && ! -f "${CERTS_DIR:-/nonexistent}/domains/local-dev.crt" ]]; then
        log_error "Certificates not found. Run: ./setup-ca.sh --env local"
        exit 1
    fi

    log_info "Requirements satisfied (env: $ENV, domain: $DOMAIN)"
}

check_all_requirements() {
    log_step "Checking all requirements..."

    local missing=()
    command -v kubectl &>/dev/null || missing+=("kubectl")
    command -v helm &>/dev/null || missing+=("helm")
    command -v openssl &>/dev/null || missing+=("openssl")
    command -v jq &>/dev/null || missing+=("jq")
    command -v envsubst &>/dev/null || missing+=("envsubst (gettext)")
    command -v curl &>/dev/null || missing+=("curl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        log_error "Make sure Rancher Desktop (or your K8s) is running."
        exit 1
    fi

    log_info "All requirements satisfied"
}

# =============================================================================
# Common Path Setup
# =============================================================================

# Set up standard paths based on SCRIPT_DIR and ENV.
# Call after parse_env_arg, before parse_config.
# Sets: K8S_DIR, BASE_DIR, ARGOCD_DIR, OVERLAY_DIR, CERTS_DIR, SCRIPT_ENV_DIR
setup_paths() {
    K8S_DIR="${SCRIPT_DIR}/.."
    BASE_DIR="${K8S_DIR}/base"
    ARGOCD_DIR="${K8S_DIR}/argocd"
    OVERLAY_DIR="${K8S_DIR}/overlays/${ENV}"
    CERTS_DIR="${K8S_DIR}/certs"
    SCRIPT_ENV_DIR="${SCRIPT_DIR}/${ENV}"

    # Ensure generated-files directory exists
    mkdir -p "${SCRIPT_ENV_DIR}"
    chmod 700 "${SCRIPT_ENV_DIR}"

    # Scratch space for rendered Helm values (removed on exit).
    init_render_dir
}
