#!/bin/bash
set -euo pipefail

# =============================================================================
# Vault Initialization and Configuration
# =============================================================================
# Usage: ./setup-vault.sh --env <env> <action>
#   all | init | unseal | configure | seed-secrets | audit
#   admin-token | renew-admin | new-root | revoke-root | status
#
# Key handling
# ------------
# With cloud KMS auto-unseal (tofu provisions the key; deploy.sh wires it up)
# Vault unseals itself and the only sensitive artefacts are *recovery* keys.
#
# No key material is ever printed to stdout: quickstart tees every step through
# _setup/<env>/logs/*.log, so printing would give the "only copy" a second
# plaintext home on disk. The gitignored mode-600 file is the copy; the scripts
# print its path and the jq command to read it.
#
# Without KMS, unseal keys are written to a gitignored file with mode 600. They
# are deliberately NOT copied into a Kubernetes secret any more: keeping unseal
# keys plus the root token inside the very cluster Vault protects makes read
# access to one namespace's secrets equivalent to holding Vault's master key.
#
# `all` creates a long-lived `platform-admin` token, stores it in the same keys
# file, and then revokes the root token. Admin work uses that token from then on.
# Vault 2.0 authenticates sys/generate-root (CVE-2026-5807), so the key quorum
# alone can no longer mint a new root: `new-root` needs the admin token too. Losing
# the keys file therefore means re-initialising Vault — the same as losing the
# unseal keys already did.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
# Empty-array expansion is unsafe under `set -u` on older bash.
if [[ ${#ARGS[@]} -gt 0 ]]; then set -- "${ARGS[@]}"; else set --; fi

setup_paths
parse_config
use_env_kubeconfig
# Repo convention: never touch a cluster without checking it is the right one.
# Without this, `--env local` while a prod kubeconfig was active would initialise
# (or re-seed) the prod cluster's Vault and cross-write its key file.
require_cluster_match

# Keys file stored per-environment (gitignored, mode 600)
KEYS_FILE="${SCRIPT_ENV_DIR}/vault-init-keys.json"

VAULT_EXEC="kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200"

# Credentials tofu generated (used by seed-secrets)
SECRETS_FILE="${SCRIPT_ENV_DIR}/secrets.env"
[[ -f "$SECRETS_FILE" ]] && { set -a; source "$SECRETS_FILE"; set +a; }

# =============================================================================
# Helpers
# =============================================================================

vault_status_json() {
    $VAULT_EXEC vault status -format=json 2>/dev/null || echo '{}'
}

# True when Vault is configured with a cloud KMS seal (auto-unseal).
auto_unseal_enabled() {
    local seal
    seal="$(vault_status_json | jq -r '.type // empty')"
    case "$seal" in
        awskms|azurekeyvault|gcpckms|transit) return 0 ;;
        *) return 1 ;;
    esac
}

require_keys_file() {
    if [[ ! -f "${KEYS_FILE}" ]]; then
        log_error "Vault key material not found: ${KEYS_FILE}"
        log_error ""
        log_error "This file is written once, at init, and is intentionally not"
        log_error "backed up into the cluster. If it is lost:"
        log_error "  - with KMS auto-unseal: Vault keeps running, but admin access is"
        log_error "    gone with the admin token that was stored here"
        log_error "  - without KMS: Vault cannot be unsealed either"
        log_error "  - without KMS: Vault cannot be unsealed and must be re-initialised"
        exit 1
    fi
}

# Resolve the token every vault_admin call runs with, and refuse to hand back
# anything that is not token-shaped.
#
# The admin token replaces root for day-to-day platform work, and — since Vault
# 2.0 made sys/generate-root an authenticated endpoint (CVE-2026-5807) — it is
# also what makes root regeneration possible at all. Unseal keys alone are no
# longer enough.
#
# This deliberately does not `exit`: it is always called from inside a `$( )`,
# where `exit` only kills the substitution's subshell. That is exactly how the
# previous `local token="${VAULT_TOKEN:-$(root_token)}"` went wrong — root_token's
# `exit 1` ended the subshell, `token` came out empty, and every following call
# ran with VAULT_TOKEN="". Vault answered 403 to all of them, so the run's errors
# pointed at Vault instead of at the missing token. Returning non-zero makes the
# caller's assignment fail, which `set -e` turns into a real stop.
resolve_vault_token() {
    local token="${VAULT_TOKEN:-}"

    if [[ -z "$token" ]]; then
        if [[ ! -f "${KEYS_FILE}" ]]; then
            log_error "Vault key material not found: ${KEYS_FILE}"
            log_error "It is written once, at init, and never stored in the cluster."
            log_error "Pass another token instead: VAULT_TOKEN=<token> $0 --env ${ENV} ..."
            return 1
        fi
        token="$(jq -r '.admin_token // .root_token // empty' "${KEYS_FILE}" 2>/dev/null || true)"
    fi

    if [[ -z "$token" ]]; then
        log_error "No admin or root token in ${KEYS_FILE}."
        log_error "Vault 2.0 requires a valid token to regenerate root, so the key"
        log_error "quorum on its own cannot recover admin access. Options:"
        log_error "  - use another token: VAULT_TOKEN=<token> ./setup-vault.sh --env ${ENV} ..."
        log_error "  - or re-initialise Vault (destroys its data)"
        return 1
    fi

    # Vault tokens are opaque single words (hvs.* today, s.* / 26 chars before).
    # Anything with whitespace or shorter than that is a truncated file or an
    # error message that leaked through a pipeline — using it would produce a
    # confusing 403 several steps later.
    if [[ ${#token} -lt 20 || "$token" == *[[:space:]]* ]]; then
        log_error "The token from ${KEYS_FILE} is not token-shaped (${#token} chars)"
        log_error "Expected something like hvs.<random>. Refusing to continue."
        return 1
    fi

    printf '%s' "$token"
}

# Run a vault command with an admin token.
vault_admin() {
    local token
    token="$(resolve_vault_token)" || return 1
    kubectl exec -n vault vault-0 -- env \
        VAULT_ADDR=http://127.0.0.1:8200 \
        VAULT_TOKEN="$token" \
        vault "$@"
}

# Same, but forwards stdin (policy writes, and KV values that must stay off argv).
vault_admin_stdin() {
    local token
    token="$(resolve_vault_token)" || return 1
    kubectl exec -i -n vault vault-0 -- env \
        VAULT_ADDR=http://127.0.0.1:8200 \
        VAULT_TOKEN="$token" \
        vault "$@"
}

# Like vault_admin, but prefers the *root* token.
#
# sys/audit is root-only on purpose — the platform-admin policy denies it, so a
# leaked admin token cannot switch auditing off. That also means enabling the
# audit device cannot go through vault_admin once an admin token exists.
vault_root() {
    local token="${VAULT_TOKEN:-}"
    if [[ -z "$token" && -f "${KEYS_FILE}" ]]; then
        token="$(jq -r '.root_token // .admin_token // empty' "${KEYS_FILE}" 2>/dev/null || true)"
    fi
    [[ -n "$token" ]] || return 1
    kubectl exec -n vault vault-0 -- env \
        VAULT_ADDR=http://127.0.0.1:8200 \
        VAULT_TOKEN="$token" \
        vault "$@"
}

# True when the keys file still holds a usable root token.
have_root_token() {
    [[ -n "${VAULT_TOKEN:-}" ]] && return 0
    [[ -f "${KEYS_FILE}" ]] || return 1
    [[ -n "$(jq -r '.root_token // empty' "${KEYS_FILE}" 2>/dev/null || true)" ]]
}

# kv_put <path> <json-object> — write a KV secret with the values on stdin.
#
# `vault kv put <path> key=value` puts every value in the exec'd command's
# arguments, which are recorded in the Kubernetes API audit log (the exec
# subresource carries the full command) and visible in `ps` on the node. Vault's
# CLI reads a JSON object from stdin when the data argument is `-`.
kv_put() {
    local path="$1" json="$2"
    printf '%s' "$json" | vault_admin_stdin kv put "$path" - >/dev/null
}

# =============================================================================
# Init / unseal
# =============================================================================

init_vault() {
    log_step "Initializing Vault..."

    local status
    status="$(vault_status_json)"

    # Compare the raw value: jq's `//` substitutes on `false` as well as null.
    if [[ "$(echo "$status" | jq -r '.initialized')" == "true" ]]; then
        log_warn "Vault is already initialized"
        return 0
    fi

    local init_output
    if auto_unseal_enabled; then
        log_info "Cloud KMS seal detected — initialising with recovery keys"
        init_output="$($VAULT_EXEC vault operator init -format=json \
            -recovery-shares=5 -recovery-threshold=3)"
    else
        log_warn "No cloud KMS seal — Vault needs manual unsealing after every restart"
        log_warn "Provision the KMS key with tofu to enable auto-unseal"
        init_output="$($VAULT_EXEC vault operator init -format=json)"
    fi

    umask 077
    mkdir -p "${SCRIPT_ENV_DIR}"
    echo "$init_output" > "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"

    # Remove any legacy in-cluster copy of the key material.
    if kubectl get secret vault-init-keys -n vault &>/dev/null; then
        kubectl delete secret vault-init-keys -n vault
        log_warn "Deleted the legacy vault-init-keys secret from the cluster."
        log_warn "Unseal keys and a root token stored next to the data they protect"
        log_warn "made namespace-level secret read equivalent to Vault root."
    fi

    log_info "Vault initialized. Key material: ${KEYS_FILE} (mode 600)"
    echo ""
    log_warn "MOVE THIS FILE TO OFFLINE STORAGE (password manager / HSM / sealed envelope)."
    log_warn "It is the only copy — nothing writes it back into the cluster."
    echo ""

    # The keys are deliberately NOT printed. quickstart runs every step through
    # `tee _setup/<env>/logs/*.log`, so printing them would put the "only copy"
    # into a second plaintext file on disk — plus shell scrollback and whatever
    # terminal recording or shared screen is in play. The file is the copy.
    if auto_unseal_enabled; then
        echo "Recovery keys (5, threshold 3 — needed only to generate a new root token):"
    else
        echo "Unseal keys (5, 3 required at every restart):"
    fi
    echo "  ${KEYS_FILE}"
    echo ""
    echo "  Read them when you actually need them, then move the file off this machine:"
    if auto_unseal_enabled; then
        echo "    jq -r '.recovery_keys_b64[]' ${KEYS_FILE}"
    else
        echo "    jq -r '.unseal_keys_b64[]' ${KEYS_FILE}"
    fi
    echo ""
}

unseal_vault() {
    if auto_unseal_enabled; then
        log_info "Cloud KMS auto-unseal is active — nothing to unseal"
        $VAULT_EXEC vault status 2>/dev/null | grep -E 'Seal Type|Sealed' || true
        return 0
    fi

    log_step "Unsealing Vault..."
    require_keys_file

    # Threshold comes from the file Vault itself wrote, rather than a hardcoded 3,
    # so changing unsealShares/unsealThreshold does not silently submit too few.
    local threshold keys
    threshold="$(jq -r '.unseal_threshold // 3' "${KEYS_FILE}")"
    keys="$(jq -r '.unseal_keys_b64[]' "${KEYS_FILE}" | head -n "$threshold")"

    local unsealed_any=0
    for pod in vault-0 vault-1 vault-2; do
        kubectl get pod "$pod" -n vault &>/dev/null || continue
        log_info "Unsealing $pod..."
        for key in $keys; do
            vault_submit_unseal_key "$pod" "$key" || true
        done

        if pod_is_sealed "$pod"; then
            log_error "$pod is still sealed after submitting ${threshold} key shares"
            log_error "Check the keys in ${KEYS_FILE} against this Vault's initialisation"
            return 1
        fi
        log_info "$pod unsealed"
        unsealed_any=1
    done

    if [[ "$unsealed_any" -eq 0 ]]; then
        log_error "No Vault pod found in namespace vault — nothing to unseal"
        return 1
    fi

    log_info "Vault unsealed"
}

# Submit one unseal key share to a pod, over the HTTP API rather than the CLI.
#
# `vault operator unseal` takes the key as an argument only: it refuses a piped
# key outright ("file descriptor 0 is not a terminal"), and `unseal -` is not a
# stdin sentinel — the literal "-" is sent as the key, which fails with "'key'
# must be a valid hex or base64 string". An argument is what we are trying to
# avoid: `kubectl exec` records the whole command in the Kubernetes API audit log
# and it shows up in `ps` on the node. A request body does neither, so the key
# goes into the JSON body of PUT /v1/sys/unseal, piped in on stdin.
#
# wget, not curl: the Vault image ships busybox only.
vault_submit_unseal_key() {
    local pod="$1" key="$2"

    printf '{"key":"%s"}' "$key" | kubectl exec -i -n vault "$pod" -- \
        sh -c 'wget -q -O- --post-file /dev/stdin http://127.0.0.1:8200/v1/sys/unseal' \
        >/dev/null 2>&1
}

# True when the pod reports Sealed=true. `vault status` exits 2 when sealed, so
# the exit code cannot be used to tell "sealed" from "unreachable".
pod_is_sealed() {
    local pod="$1" sealed
    sealed="$(kubectl exec -n vault "$pod" -- \
        env VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null \
        | jq -r '.sealed' 2>/dev/null)"
    [[ "$sealed" != "false" ]]
}

# =============================================================================
# Configuration
# =============================================================================

configure_k8s_auth() {
    log_step "Configuring Kubernetes authentication..."

    vault_admin auth enable kubernetes 2>/dev/null || log_info "kubernetes auth already enabled"

    # Resolved here, not inline in the command below: `$(root_token)` inside the
    # heredoc runs in a subshell, so a failure there produced VAULT_TOKEN='' and
    # a 403 rather than a stop.
    local token
    token="$(resolve_vault_token)" || return 1

    kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$token" sh -c "
        export VAULT_ADDR=http://127.0.0.1:8200
        vault write auth/kubernetes/config \
            kubernetes_host=https://\$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT \
            kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    "

    log_info "Kubernetes authentication configured"
}

# Audit logging. Vault's audit devices are opt-in: until one is enabled Vault
# keeps no request log at all. The platform provisioned audit storage
# (auditStorage in the Vault chart values, mounted at /vault/audit) and the
# platform-admin policy denies sys/audit* "so a leaked admin token cannot switch
# auditing off" — but nothing ever enabled a device, so that denial was guarding
# a log that did not exist.
#
# Must run BEFORE the root token is revoked, and before create_admin_token makes
# vault_admin prefer the admin token: sys/audit is exactly what platform-admin
# cannot touch. Hence vault_root.
enable_audit_device() {
    log_step "Enabling the file audit device..."

    if vault_root audit list -format=json 2>/dev/null | jq -e 'has("file/")' >/dev/null 2>&1; then
        log_info "Audit device file/ already enabled"
        return 0
    fi

    if vault_root audit enable file file_path=/vault/audit/audit.log >/dev/null; then
        log_info "Audit device enabled: file → /vault/audit/audit.log (PVC vault-audit)"
        log_info "Vault refuses requests it cannot audit, so watch this volume's free space."
        return 0
    fi

    # No root token left: an environment set up before this step existed. Say
    # how to fix it rather than failing a configure re-run that is otherwise fine.
    if ! have_root_token; then
        log_warn "Could not enable the audit device: sys/audit needs a root token and"
        log_warn "the initial one has been revoked. Enable it with:"
        log_warn "  ./setup-vault.sh --env ${ENV} new-root"
        log_warn "  ./setup-vault.sh --env ${ENV} audit"
        log_warn "  ./setup-vault.sh --env ${ENV} revoke-root"
        return 0
    fi

    log_error "Could not enable the audit device even though a root token is available."
    log_error "Check that the Vault pod has /vault/audit mounted and writable"
    log_error "(server.auditStorage.enabled in k8s/base/devops/vault/values.yaml)."
    return 1
}

# Human SSO: the Keycloak realm (which brokers Entra) becomes an OIDC auth
# method, so `vault login -method=oidc` and the UI's OIDC tab work for people.
# The devops-admins group maps to the platform-admin policy through Vault's
# external identity groups; everyone else lands on the default policy.
#
# The discovery URL is the *external* Keycloak address on purpose: Vault
# insists the issuer in tokens equals the discovery URL, and the issuer is
# always KC_HOSTNAME. Reaching it from the pod relies on the hairpin DNS
# rewrite deploy.sh installs (pods otherwise cannot dial their own LB).
configure_oidc_auth() {
    log_step "Configuring OIDC auth (human SSO via Keycloak)..."

    local client_secret
    client_secret="$(kubectl get secret vault-oidc-secret -n vault \
        -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d || true)"
    if [[ -z "$client_secret" ]]; then
        log_warn "vault-oidc-secret not found — run setup-keycloak.sh first, then:"
        log_warn "  ./setup-vault.sh --env ${ENV} oidc"
        return 0
    fi

    vault_admin auth enable oidc 2>/dev/null || log_info "oidc auth already enabled"

    # Vault fetches the discovery document itself, so it has to trust the
    # certificate on https://keycloak.${DOMAIN}. With a local CA that is not in
    # any system trust store, and the write fails with "error checking oidc
    # discovery URL". oidc_discovery_ca_pem takes the CA inline; it is a public
    # certificate, so passing it as an argument leaks nothing.
    local ca_args=()
    if [[ "$TLS_TYPE" == "local-ca" && -f "${CERTS_DIR}/ca/ca.crt" ]]; then
        ca_args=("oidc_discovery_ca_pem=$(cat "${CERTS_DIR}/ca/ca.crt")")
        log_info "Using the local CA for OIDC discovery"
    fi

    # Not silenced and not ignored: this failing is what leaves Vault with no
    # human SSO at all, and it used to be followed by an unconditional
    # "OIDC auth configured".
    if ! vault_admin write auth/oidc/config \
        oidc_discovery_url="https://keycloak.${DOMAIN}/realms/devops" \
        oidc_client_id="vault" \
        oidc_client_secret="${client_secret}" \
        "${ca_args[@]+"${ca_args[@]}"}" \
        default_role="default" >/dev/null; then
        log_error "Could not configure OIDC auth against https://keycloak.${DOMAIN}/realms/devops"
        log_error "Vault must be able to reach Keycloak and trust its certificate."
        if [[ "$ENV" == "local" ]]; then
            log_error "On local this needs the keycloak.${DOMAIN} hostAlias on the Vault pod:"
            log_error "  ./deploy.sh --env ${ENV} vault && ./setup-vault.sh --env ${ENV} oidc"
        fi
        return 1
    fi

    vault_admin write auth/oidc/role/default \
        bound_audiences="vault" \
        allowed_redirect_uris="https://vault.${DOMAIN}/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
        user_claim="preferred_username" \
        groups_claim="groups" \
        oidc_scopes="openid,profile,email,groups" \
        token_policies="default" \
        token_ttl=1h token_max_ttl=8h >/dev/null

    # devops-admins (a Keycloak group fed by the Entra App Role) → platform-admin.
    # External identity groups match on the group alias equal to the claim value.
    local accessor group_id
    accessor="$(vault_admin auth list -format=json | jq -r '."oidc/".accessor')"
    group_id="$(vault_admin read -format=json identity/group/name/devops-admins 2>/dev/null \
        | jq -r '.data.id // empty' || true)"
    if [[ -z "$group_id" ]]; then
        group_id="$(vault_admin write -format=json identity/group \
            name=devops-admins type=external policies=platform-admin | jq -r '.data.id')"
    else
        vault_admin write identity/group/id/"${group_id}" \
            name=devops-admins type=external policies=platform-admin >/dev/null
    fi
    vault_admin write identity/group-alias \
        name="/devops-admins" mount_accessor="${accessor}" canonical_id="${group_id}" >/dev/null 2>&1 \
        || log_info "group-alias /devops-admins already present"

    log_info "OIDC auth configured — UI: 'OIDC' method; CLI: vault login -method=oidc"
}

# A named admin identity, so the root token can be revoked without losing the
# ability to administer Vault. Stored alongside the unseal keys — the file is
# already the crown jewels, and Vault 2.0 needs a token for root regeneration.
create_admin_token() {
    require_keys_file

    if [[ -n "$(jq -r '.admin_token // empty' "${KEYS_FILE}")" ]]; then
        # Still valid? A stale token in the file is worse than none.
        if kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
             VAULT_TOKEN="$(jq -r '.admin_token' "${KEYS_FILE}")" \
             vault token lookup >/dev/null 2>&1; then
            log_info "Platform admin token already exists"
            return 0
        fi
        log_warn "Stored admin token is no longer valid — creating a new one"
    fi

    log_step "Creating the platform admin token..."

    vault_admin_stdin policy write platform-admin - <<'EOF'
# Everything except the ability to hide its own tracks: audit devices are
# root-only on purpose, so a compromised admin token cannot disable auditing.
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "sys/audit*" {
  capabilities = ["deny"]
}
EOF

    local token
    token="$(vault_admin token create -policy=platform-admin -orphan \
        -display-name=platform-admin -ttl=8760h -renewable=true -format=json \
        | jq -r '.auth.client_token')"
    [[ -n "$token" && "$token" != "null" ]] || { log_error "Could not create the admin token"; exit 1; }

    local tmp; tmp="$(mktemp)"
    jq --arg t "$token" '.admin_token = $t' "${KEYS_FILE}" > "$tmp" && mv "$tmp" "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"

    log_info "Admin token stored in ${KEYS_FILE} (1 year, renewable)"
    log_info "Renew with: ./setup-vault.sh --env ${ENV} renew-admin"
}

renew_admin_token() {
    require_keys_file
    local token
    token="$(jq -r '.admin_token // empty' "${KEYS_FILE}")"
    [[ -n "$token" ]] || { log_error "No admin token in ${KEYS_FILE}"; exit 1; }

    kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
        VAULT_TOKEN="$token" vault token renew >/dev/null
    log_info "Admin token renewed for another year"
}

create_platform_roles() {
    log_step "Creating Vault policies and roles..."

    vault_admin secrets enable -path=secret kv-v2 2>/dev/null || log_info "KV v2 already enabled at secret/"

    # External Secrets: platform credentials and app secrets only. The previous
    # policy granted read on secret/data/* — every secret Vault holds, including
    # other clusters' material.
    vault_admin_stdin policy write external-secrets - <<'EOF'
path "secret/data/platform/*" {
  capabilities = ["read"]
}
path "secret/metadata/platform/*" {
  capabilities = ["list", "read"]
}
path "secret/data/apps/*" {
  capabilities = ["read"]
}
path "secret/metadata/apps/*" {
  capabilities = ["list", "read"]
}
path "secret/data/forgejo/registry-pull-token" {
  capabilities = ["read"]
}
EOF

    vault_admin write auth/kubernetes/role/external-secrets \
        bound_service_account_names=external-secrets \
        bound_service_account_namespaces=external-secrets \
        policies=external-secrets \
        ttl=1h

    # Raft snapshots: the CronJob authenticates as itself and may do exactly one
    # thing. No root token in a scheduled job.
    vault_admin_stdin policy write vault-snapshot - <<'EOF'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF

    vault_admin write auth/kubernetes/role/vault-snapshot \
        bound_service_account_names=vault-snapshot \
        bound_service_account_namespaces=vault \
        policies=vault-snapshot \
        ttl=15m

    log_info "Policies created: external-secrets, vault-snapshot"

    # ClusterSecretStore for the platform cluster's own ExternalSecrets. Skipped
    # when the operator is not installed yet — Vault configuration is still valid
    # without it, and deploy.sh's platform-secrets step applies it later.
    if kubectl get crd clustersecretstores.external-secrets.io &>/dev/null; then
        kubectl apply -f "${BASE_DIR}/devops/external-secrets/cluster-secret-store.yaml"
        log_info "ClusterSecretStore 'vault-backend' applied"
    else
        log_warn "External Secrets Operator not installed — skipping the ClusterSecretStore"
        log_warn "Install it, then: ./devhub deploy --env ${ENV} external-secrets"
    fi
}

# Seed the platform's own credentials into Vault so Vault — not a pile of
# hand-created K8s secrets — is the source of truth. Idempotent: existing values
# are left alone unless --force is passed.
seed_platform_secrets() {
    log_step "Seeding platform secrets into Vault..."

    local force="${1:-}"

    _kv_exists() {
        vault_admin kv get -format=json "secret/$1" &>/dev/null
    }

    _read_k8s() {
        kubectl get secret "$2" -n "$1" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true
    }

    # PostgreSQL — from tofu (managed) or from the bootstrap secrets (local).
    #
    # Read from data-services, never from the consuming namespaces: those Secrets
    # are the ones platform-secrets deletes to hand ownership to External Secrets,
    # so on a re-seed they may be absent — and seeding an empty password produces a
    # Secret that syncs happily and then fails authentication at the database.
    local pg_admin="${PG_ADMIN_PASSWORD:-$(_read_k8s data-services postgresql-credentials postgres-password)}"
    local pg_keycloak="${PG_KEYCLOAK_PASSWORD:-$(_read_k8s data-services postgresql-credentials keycloak-password)}"
    local pg_forgejo="${PG_FORGEJO_PASSWORD:-$(_read_k8s data-services postgresql-credentials forgejo-password)}"
    [[ -n "$pg_forgejo" ]] || pg_forgejo="$(_read_k8s data-services forgejo-db-credentials password)"

    if [[ -n "$pg_keycloak" && -n "$pg_forgejo" ]]; then
        if [[ "$force" == "--force" ]] || ! _kv_exists platform/postgres; then
            # The usernames are here because the Keycloak Operator wants both keys
            # in one secret, and keeping them together means a rotation is a single
            # `vault kv patch` rather than a patch plus a manifest edit.
            kv_put secret/platform/postgres "$(jq -n \
                --arg admin "$pg_admin" \
                --arg kc "$pg_keycloak" \
                --arg fj "$pg_forgejo" \
                '{"admin-password":$admin,
                  "keycloak-username":"keycloak","keycloak-password":$kc,
                  "forgejo-username":"forgejo","forgejo-password":$fj}')"
            log_info "  secret/platform/postgres"
        else
            log_info "  secret/platform/postgres (exists, left as-is)"
        fi
    else
        log_error "  no PostgreSQL credentials found to seed (keycloak='${pg_keycloak:+set}' forgejo='${pg_forgejo:+set}')"
        log_error "  Seeding a partial secret/platform/postgres would break Keycloak or"
        log_error "  Forgejo on the next restart, so nothing was written."
        exit 1
    fi

    # Redis / Valkey
    local redis_pw="${REDIS_PASSWORD:-}"
    if [[ -n "$redis_pw" ]]; then
        if [[ "$force" == "--force" ]] || ! _kv_exists platform/redis; then
            kv_put secret/platform/redis "$(jq -n --arg p "$redis_pw" '{password:$p}')"
            log_info "  secret/platform/redis"
        else
            log_info "  secret/platform/redis (exists, left as-is)"
        fi
    fi

    # Grafana admin
    local graf_user graf_pw
    graf_user="$(_read_k8s monitoring grafana-admin-secret admin-user)"
    graf_pw="$(_read_k8s monitoring grafana-admin-secret admin-password)"
    if [[ -n "$graf_pw" ]]; then
        if [[ "$force" == "--force" ]] || ! _kv_exists platform/grafana; then
            kv_put secret/platform/grafana "$(jq -n \
                --arg u "${graf_user:-admin}" --arg p "$graf_pw" \
                '{"admin-user":$u,"admin-password":$p}')"
            log_info "  secret/platform/grafana"
        else
            log_info "  secret/platform/grafana (exists, left as-is)"
        fi
    fi

    # Shared gateway OIDC client for developer apps (created by
    # setup-keycloak.sh as client "apps"). Lives under apps/, not platform/,
    # because workload clusters' Vault policy is limited to apps/* — the
    # devhub-app chart's ExternalSecret pulls it into each app namespace.
    local apps_oidc="${APPS_OIDC_SECRET:-}"
    [[ -n "$apps_oidc" ]] || apps_oidc="$(grep -s '^APPS_OIDC_SECRET=' "${SCRIPT_ENV_DIR}/oidc-secrets.env" | tail -1 | cut -d= -f2-)"
    if [[ -n "$apps_oidc" ]]; then
        if [[ "$force" == "--force" ]] || ! _kv_exists apps/oidc-gateway; then
            kv_put secret/apps/oidc-gateway "$(jq -n --arg s "$apps_oidc" '{"client-secret":$s}')"
            log_info "  secret/apps/oidc-gateway"
        else
            log_info "  secret/apps/oidc-gateway (exists, left as-is)"
        fi
    fi

    # Alertmanager webhook — created (possibly empty) so the ExternalSecret resolves.
    if [[ "$force" == "--force" ]] || ! _kv_exists platform/alertmanager; then
        local webhook
        webhook="$(_read_k8s monitoring alertmanager-slack webhook-url)"
        kv_put secret/platform/alertmanager "$(jq -n --arg w "$webhook" '{"webhook-url":$w}')"
        log_info "  secret/platform/alertmanager${webhook:+ (webhook set)}"
    fi

    # `kv patch`, not `kv put`: KV v2 writes are whole-version replacements, so a
    # `put` of one key on a multi-property secret — secret/platform/postgres holds
    # the admin, keycloak and forgejo credentials together — deletes the others.
    # ExternalSecrets then fails on its next refresh and Keycloak or Forgejo stops
    # authenticating at the next restart.
    log_info "Rotate any of these with: vault kv patch secret/platform/<name> <key>=<value>"
}

# Regenerate a *root* token. Rarely needed — the admin token covers normal work —
# but some operations (audit devices, seal migration) still want real root.
#
# Since Vault 2.0, sys/generate-root is authenticated: the key quorum alone will
# not do it, so this needs the admin token (or VAULT_TOKEN) as well.
new_root_token() {
    require_keys_file

    if [[ -n "$(jq -r '.root_token // empty' "${KEYS_FILE}")" ]]; then
        log_info "A root token is already present in ${KEYS_FILE}"
        return 0
    fi

    local admin="${VAULT_TOKEN:-$(jq -r '.admin_token // empty' "${KEYS_FILE}")}"
    if [[ -z "$admin" ]]; then
        log_error "Root generation needs a valid token as well as the key quorum"
        log_error "(Vault 2.0 authenticates sys/generate-root)."
        log_error "Set VAULT_TOKEN=<token> and re-run."
        exit 1
    fi

    log_step "Generating a new root token from the key quorum..."

    local vx=(kubectl exec -n vault vault-0 -- env
              VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$admin")
    # Same, forwarding stdin: the unseal shares go in that way rather than as
    # arguments, which the Kubernetes API audit log records verbatim.
    local vxi=(kubectl exec -i -n vault vault-0 -- env
               VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$admin")

    # Cancel any half-finished attempt; a stale nonce makes every share fail.
    "${vx[@]}" vault operator generate-root -cancel >/dev/null 2>&1 || true

    local init nonce otp threshold
    init="$("${vx[@]}" vault operator generate-root -init -format=json 2>/dev/null || echo '{}')"
    nonce="$(echo "$init" | jq -r '.nonce // empty')"
    otp="$(echo "$init" | jq -r '.otp // empty')"
    [[ -n "$nonce" && -n "$otp" ]] || { log_error "Could not start root generation"; exit 1; }

    threshold="$(vault_status_json | jq -r '.t // 3')"

    local i key out encoded=""
    for ((i = 0; i < threshold; i++)); do
        key="$(jq -r ".unseal_keys_b64[$i] // .recovery_keys_b64[$i] // empty" "${KEYS_FILE}")"
        [[ -n "$key" ]] || { log_error "Only $i keys available, need ${threshold}"; exit 1; }
        out="$(printf '%s\n' "$key" | "${vxi[@]}" \
            vault operator generate-root -nonce="$nonce" -format=json - 2>/dev/null || echo '{}')"
        encoded="$(echo "$out" | jq -r '.encoded_token // empty')"
    done
    [[ -n "$encoded" ]] || { log_error "Root generation did not complete"; exit 1; }

    local token
    token="$("${vx[@]}" vault operator generate-root \
        -decode="$encoded" -otp="$otp" -format=json 2>/dev/null | jq -r '.token // empty')"
    [[ -n "$token" ]] || { log_error "Could not decode the generated root token"; exit 1; }

    local tmp; tmp="$(mktemp)"
    jq --arg t "$token" '.root_token = $t' "${KEYS_FILE}" > "$tmp" && mv "$tmp" "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"

    log_info "New root token written to ${KEYS_FILE}"
    log_warn "Revoke it when you are done: ./setup-vault.sh --env ${ENV} revoke-root"
}

# The root token exists to bootstrap. Leaving it in a file on a laptop is a
# standing risk with no upside.
revoke_root_token() {
    require_keys_file
    local token
    token="$(jq -r '.root_token // empty' "${KEYS_FILE}")"

    if [[ -z "$token" ]]; then
        log_info "Root token already revoked"
        return 0
    fi

    log_step "Revoking the initial root token..."

    kubectl exec -n vault vault-0 -- env \
        VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" \
        vault token revoke -self >/dev/null 2>&1 || true

    # Drop it from the key file too, so the file only holds unseal/recovery keys.
    local tmp
    tmp="$(mktemp)"
    jq 'del(.root_token)' "${KEYS_FILE}" > "$tmp" && mv "$tmp" "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"

    log_info "Root token revoked and removed from ${KEYS_FILE}"
    log_info "Need admin access later: ./setup-vault.sh --env ${ENV} new-root"
}

print_summary() {
    echo ""
    echo "=============================================="
    echo "Vault Setup Complete"
    echo "=============================================="
    echo ""
    if auto_unseal_enabled; then
        echo "  Seal:       cloud KMS auto-unseal (restarts unseal themselves)"
    else
        echo "  Seal:       manual (3 of 5 unseal keys after every restart)"
        echo "              Provision the KMS key with tofu to remove this step."
    fi
    echo "  Keys:       ${KEYS_FILE}  (mode 600, gitignored, NOT in the cluster)"
    echo "              never printed — read with: jq -r '.unseal_keys_b64[]' <file>"
    echo "  Audit:      file device → /vault/audit/audit.log (PVC vault-audit)"
    echo "  Root token: revoked — regenerate with './setup-vault.sh --env ${ENV} new-root'"
    echo "  Snapshots:  CronJob vault-raft-snapshot every 6h → PVC vault-snapshots"
    echo ""
    echo "  Platform credentials live at secret/platform/* and are delivered by"
    echo "  External Secrets. Finish the switch with:"
    echo "    ./deploy.sh --env ${ENV} platform-secrets"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    local action="${1:-all}"

    echo "=============================================="
    echo "Vault Setup (${ENV}) — ${action}"
    echo "=============================================="

    case "$action" in
        all)
            init_vault
            unseal_vault
            configure_k8s_auth
            create_platform_roles
            configure_oidc_auth
            # Before create_admin_token (which makes vault_admin prefer the
            # admin token, whose policy denies sys/audit*) and before
            # revoke_root_token (which throws root away).
            enable_audit_device
            create_admin_token
            seed_platform_secrets
            revoke_root_token
            print_summary
            ;;
        init)          init_vault ;;
        unseal)        unseal_vault ;;
        configure)     configure_k8s_auth && create_platform_roles && configure_oidc_auth \
                           && enable_audit_device && create_admin_token ;;
        audit)         enable_audit_device ;;
        oidc)          configure_oidc_auth ;;
        seed-secrets)  seed_platform_secrets "${2:-}" ;;
        admin-token)   create_admin_token ;;
        renew-admin)   renew_admin_token ;;
        new-root)      new_root_token ;;
        revoke-root)   revoke_root_token ;;
        status)        $VAULT_EXEC vault status || true ;;
        *)
            echo "Usage: $0 --env <env> [all|init|unseal|configure|oidc|audit|seed-secrets|admin-token|renew-admin|new-root|revoke-root|status]"
            exit 1
            ;;
    esac
}

main "$@"
