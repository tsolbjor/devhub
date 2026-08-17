#!/bin/bash
set -euo pipefail

# =============================================================================
# Register Workload Cluster with the Platform
# =============================================================================
# Wires a workload cluster into the platform:
#   1. Registers it with the platform ArgoCD, labelled devhub.io/role=workload
#      (the ApplicationSet's cluster generator selects on that label, so apps
#      start landing here with no manifest edits)
#   2. Creates a Vault JWT auth mount trusting this cluster's OIDC issuer, plus a
#      narrowly-scoped role and policy for External Secrets — no static token
#   3. Copies the platform's Loki ingest credentials so Alloy can push logs
#   4. Creates a Forgejo registry token for image pulls and stores it in Vault
#
# Usage:
#   ./register-workload-cluster.sh --env aws-workload [--platform-env aws-dev]
#
# Prerequisites:
#   - ./sync-tofu-outputs.sh has been run for BOTH environments
#   - argocd CLI installed and logged in to the platform ArgoCD
#   - Vault initialised on the platform cluster (./setup-vault.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Arguments ────────────────────────────────────────────────────────

PLATFORM_ENV=""
ENV=""
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)          ENV="${2:-}"; shift 2 ;;
        --platform-env) PLATFORM_ENV="${2:-}"; shift 2 ;;
        *)              ARGS+=("$1"); shift ;;
    esac
done

if [[ -z "$ENV" ]]; then
    log_error "Missing --env argument"
    echo "Usage: $0 --env aws-workload [--platform-env aws-dev]"
    exit 1
fi

if [[ " ${WORKLOAD_ENVS} " != *" ${ENV} "* ]]; then
    log_error "Invalid workload environment: $ENV"
    log_error "Valid: ${WORKLOAD_ENVS}"
    exit 1
fi

CLOUD="${ENV%-workload}"
if [[ -z "$PLATFORM_ENV" ]]; then
    PLATFORM_ENV="${CLOUD}-dev"
    log_warn "No --platform-env specified, defaulting to: ${PLATFORM_ENV}"
fi

setup_paths          # paths for the workload env
parse_config         # workload config.yaml + tofu-outputs.env

WORKLOAD_KUBECONFIG="${SCRIPT_DIR}/${ENV}/kubeconfig"
PLATFORM_KUBECONFIG="${PLATFORM_KUBECONFIG:-${SCRIPT_DIR}/${PLATFORM_ENV}/kubeconfig}"

if [[ ! -f "$WORKLOAD_KUBECONFIG" ]]; then
    log_error "Workload kubeconfig not found: ${WORKLOAD_KUBECONFIG}"
    log_error "Run: ./sync-tofu-outputs.sh --env ${ENV}"
    exit 1
fi

if [[ ! -f "$PLATFORM_KUBECONFIG" && "$PLATFORM_ENV" != "local" ]]; then
    log_error "Platform kubeconfig not found: ${PLATFORM_KUBECONFIG}"
    log_error "Run: ./sync-tofu-outputs.sh --env ${PLATFORM_ENV} (or set PLATFORM_KUBECONFIG)"
    exit 1
fi

# Short helpers so no command can accidentally run against the wrong cluster.
kw() { KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl "$@"; }
kp() { KUBECONFIG="$PLATFORM_KUBECONFIG" kubectl "$@"; }

WORKLOAD_OIDC_ISSUER="${OIDC_ISSUER_URL:-}"

# ─── Step 1: register with ArgoCD ─────────────────────────────────────

log_phase "Step 1: Register workload cluster with the platform ArgoCD"

WORKLOAD_SERVER="$(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl config view --minify \
    --output 'jsonpath={.clusters[0].cluster.server}')"

if command -v argocd &>/dev/null; then
    WORKLOAD_CONTEXT="$(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl config current-context)"
    log_info "Adding cluster to ArgoCD (context: ${WORKLOAD_CONTEXT})..."

    KUBECONFIG="$WORKLOAD_KUBECONFIG" argocd cluster add "$WORKLOAD_CONTEXT" \
        --name "${ENV}" \
        --label "devhub.io/role=workload" \
        --label "devhub.io/cloud=${CLOUD}" \
        --yes || log_warn "argocd cluster add returned non-zero (already registered?)"
else
    log_warn "argocd CLI not found — install it: https://argo-cd.readthedocs.io/en/stable/cli_installation/"
    log_warn "Then run: argocd cluster add <workload-context> --name ${ENV} --label devhub.io/role=workload"
fi

# The label is what makes the ApplicationSet target this cluster. Set it directly
# on the cluster Secret too, so a cluster added without --label still works.
if kp get secret -n argocd -l argocd.argoproj.io/secret-type=cluster \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -q .; then
    for secret in $(kp get secret -n argocd -l argocd.argoproj.io/secret-type=cluster \
                        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
        name="$(kp get secret "$secret" -n argocd -o jsonpath='{.data.name}' | base64 -d)"
        if [[ "$name" == "$ENV" ]]; then
            kp label secret "$secret" -n argocd \
                "devhub.io/role=workload" "devhub.io/cloud=${CLOUD}" --overwrite >/dev/null
            log_info "Labelled ArgoCD cluster secret ${secret} (devhub.io/role=workload)"
        fi
    done
fi

log_info "Cluster URL: ${WORKLOAD_SERVER}"

# ─── Step 2: Vault trust (JWT auth, no static token) ──────────────────

log_phase "Step 2: Create the Vault trust for External Secrets"

VAULT_POLICY_NAME="workload-${ENV}-secrets"
VAULT_JWT_PATH="jwt-${ENV}"
VAULT_ROLE="workload-${ENV}"

# Run a vault command on the platform cluster. Prefers a configured local CLI,
# otherwise execs into the Vault pod.
VAULT_POD=""
vault_exec() {
    if command -v vault &>/dev/null && [[ -n "${VAULT_ADDR:-}" && -n "${VAULT_TOKEN:-}" ]]; then
        vault "$@"
        return
    fi

    if [[ -z "$VAULT_POD" ]]; then
        VAULT_POD="$(kp get pod -n vault -l app.kubernetes.io/name=vault \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
    fi
    [[ -n "$VAULT_POD" ]] || return 1

    kp exec -n vault "$VAULT_POD" -- env \
        VAULT_ADDR=http://127.0.0.1:8200 \
        VAULT_TOKEN="${VAULT_TOKEN:-$(platform_root_token)}" \
        vault "$@"
}

platform_root_token() {
    local keys_file="${SCRIPT_DIR}/${PLATFORM_ENV}/vault-init-keys.json"
    if [[ -f "$keys_file" ]]; then
        jq -r '.root_token' "$keys_file"
    else
        echo ""
    fi
}

if [[ -z "$WORKLOAD_OIDC_ISSUER" ]]; then
    log_warn "No OIDC issuer in the workload tofu outputs (oidc_issuer_url)."
    log_warn "Re-run ./sync-tofu-outputs.sh --env ${ENV} after applying the workload tofu module."
    log_warn "Skipping the Vault trust — External Secrets will not work until it exists."
else
    log_info "Workload OIDC issuer: ${WORKLOAD_OIDC_ISSUER}"

    # Narrow policy: app secrets and the registry pull token, read-only. The old
    # platform-wide `secret/data/*` read is not granted here.
    if vault_exec policy write "$VAULT_POLICY_NAME" - <<EOF
# App secrets for workloads on ${ENV}
path "secret/data/apps/*" {
  capabilities = ["read"]
}
path "secret/metadata/apps/*" {
  capabilities = ["list", "read"]
}
# Registry pull credentials
path "secret/data/forgejo/registry-pull-token" {
  capabilities = ["read"]
}
EOF
    then
        log_info "Vault policy written: ${VAULT_POLICY_NAME}"

        vault_exec auth enable -path="${VAULT_JWT_PATH}" jwt 2>/dev/null \
            || log_info "JWT auth mount ${VAULT_JWT_PATH} already enabled"

        # Vault verifies tokens against the cluster's public JWKS — no
        # credentials are exchanged and nothing needs rotating.
        vault_exec write "auth/${VAULT_JWT_PATH}/config" \
            oidc_discovery_url="${WORKLOAD_OIDC_ISSUER}" \
            default_role="${VAULT_ROLE}"

        vault_exec write "auth/${VAULT_JWT_PATH}/role/${VAULT_ROLE}" \
            role_type="jwt" \
            bound_audiences="vault" \
            user_claim="sub" \
            bound_subject="system:serviceaccount:external-secrets:external-secrets" \
            token_policies="${VAULT_POLICY_NAME}" \
            token_ttl="1h" \
            token_max_ttl="4h"

        log_info "Vault JWT role ${VAULT_ROLE} bound to external-secrets/external-secrets"

        # Any leftover static token from the previous design is now dead weight.
        if kw get secret vault-workload-token -n external-secrets &>/dev/null; then
            kw delete secret vault-workload-token -n external-secrets
            log_info "Removed the obsolete static vault-workload-token secret"
        fi
    else
        log_warn "Could not reach Vault on the platform cluster."
        log_warn "Set VAULT_ADDR + VAULT_TOKEN, or check that Vault is unsealed, then re-run."
    fi
fi

# ─── Step 3: Loki ingest credentials ──────────────────────────────────

log_phase "Step 3: Copy the Loki ingest credentials"

if kp get secret loki-ingest-credentials -n monitoring &>/dev/null; then
    LOKI_USER="$(kp get secret loki-ingest-credentials -n monitoring -o jsonpath='{.data.username}' | base64 -d)"
    LOKI_PASS="$(kp get secret loki-ingest-credentials -n monitoring -o jsonpath='{.data.password}' | base64 -d)"

    kw create namespace monitoring 2>/dev/null || true
    # Keys are uppercase because Alloy reads them as environment variables.
    kw create secret generic loki-ingest-credentials \
        --namespace monitoring \
        --from-literal=USERNAME="$LOKI_USER" \
        --from-literal=PASSWORD="$LOKI_PASS" \
        --dry-run=client -o yaml | kw apply -f - >/dev/null

    log_info "Loki ingest credentials copied (user: ${LOKI_USER})"
    log_info "Restart Alloy to pick them up: kubectl rollout restart ds/alloy -n monitoring"
else
    log_warn "Platform secret monitoring/loki-ingest-credentials not found."
    log_warn "Create it on the platform cluster: ./deploy.sh --env ${PLATFORM_ENV} loki-auth"
fi

# ─── Step 4: registry pull credentials ────────────────────────────────
#
# Forgejo's container registry authenticates with a normal access token. Creating
# one over the API is a single call.

log_phase "Step 4: Create the registry pull token"

FORGEJO_POD="$(kp get pod -n forgejo -l app.kubernetes.io/name=forgejo \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"

if [[ -z "$FORGEJO_POD" ]]; then
    log_warn "Forgejo pod not found on the platform cluster."
    log_warn "Create a read-only registry token manually:"
    log_warn "  Forgejo → Settings → Applications → Generate token (scope: read:package)"
    log_warn "  vault kv put secret/forgejo/registry-pull-token username=<user> token=<token>"
else
    log_info "Forgejo pod: ${FORGEJO_POD}"

    # forgejo-cli runs inside the pod with the server's own configuration, so no
    # admin password is needed to mint a token.
    REGISTRY_USER="workload-registry-pull"
    TOKEN_OUTPUT="$(kp exec -n forgejo "${FORGEJO_POD}" -- sh -c "
        forgejo admin user create --username ${REGISTRY_USER} --random-password \
            --email ${REGISTRY_USER}@${DOMAIN} --must-change-password=false 2>/dev/null || true
        forgejo admin user generate-access-token --username ${REGISTRY_USER} \
            --token-name workload-${ENV} --scopes read:package --raw 2>&1 | tail -1
    " 2>&1 || echo "ERROR")"

    REGISTRY_TOKEN="$(echo "$TOKEN_OUTPUT" | tr -d '\r' | tail -1)"

    if [[ -n "$REGISTRY_TOKEN" && "$REGISTRY_TOKEN" != *ERROR* && "$REGISTRY_TOKEN" != *error* ]]; then
        log_info "Registry token created for ${REGISTRY_USER}"

        if vault_exec kv put secret/forgejo/registry-pull-token \
                username="${REGISTRY_USER}" \
                token="${REGISTRY_TOKEN}" \
                registry="git.${DOMAIN}"; then
            log_info "Stored at secret/forgejo/registry-pull-token"
        else
            log_warn "Vault unreachable — store it manually:"
            log_warn "  vault kv put secret/forgejo/registry-pull-token username=${REGISTRY_USER} token=<token>"
        fi
    else
        log_warn "Could not create the registry token automatically"
        log_warn "Output: ${TOKEN_OUTPUT}"
        log_warn "Create one in the Forgejo UI (scope: read:package) and store it in Vault."
    fi
fi

# ─── Summary ───────────────────────────────────────────────────────────

echo ""
log_info "Registration complete."
echo ""
echo "  Workload cluster: ${ENV}"
echo "  Platform cluster: ${PLATFORM_ENV}"
echo "  Cluster URL:      ${WORKLOAD_SERVER}"
echo ""
echo "  App delivery is automatic: the forgejo-workloads ApplicationSet matches"
echo "  clusters labelled devhub.io/role=workload, so no manifest edit is needed."
echo ""
echo "  Verify:"
echo "    argocd cluster list"
echo "    kubectl --kubeconfig ${WORKLOAD_KUBECONFIG} get clustersecretstore vault-backend"
echo "    kubectl --kubeconfig ${WORKLOAD_KUBECONFIG} logs -n monitoring ds/alloy | tail"
echo ""
