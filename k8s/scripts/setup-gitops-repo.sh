#!/bin/bash
set -euo pipefail

# =============================================================================
# Publish the GitOps repository for an environment
# =============================================================================
# devhub is an installer, not a runtime dependency. This script is the moment
# that distinction becomes real: it takes the parts of this repository the
# environment actually needs, writes them into a *standalone* repository in the
# environment's own Forgejo, and points ArgoCD at it. From then on the
# environment owns its own history and can diverge freely — nothing here is
# referenced again, and there is no upgrade path back to devhub by design.
#
# What that implies, and why the copy is not simply `git push` of this checkout:
#
#   - Other clouds and other environments are cut away. An environment repo that
#     carries nine overlays invites someone to edit the wrong one.
#   - The overlay's devops/ symlink is dereferenced. `overlays/<env>/devops ->
#     ../<cloud>/devops` is a template convenience; a standalone repo should have
#     its own files, and platform-appset.yaml already reads that exact path.
#   - backend.hcl and *.tfvars are *committed*, inverting this repository's
#     .gitignore. They hold state bucket names, allowed CIDRs and admin group
#     IDs — account-specific, not secret — and without them the next operator
#     cannot run `tofu init` at all.
#   - renovate.json ships, so chart pins keep moving after the link is cut. An
#     environment frozen at its birth date rots quietly.
#   - Installer-only scripts (quickstart, setup-env, preflight, this one) do not
#     ship. They set an environment up; they have no meaning inside one.
#
# Secrets never ship. The staged tree is scanned before the commit, and the
# script aborts on anything that looks like a credential.
#
# Usage: ./setup-gitops-repo.sh --env <env> [options]
#
#   --stage-only <dir>   build the repository into <dir> and stop (no cluster,
#                        no push) — the way to inspect what would be published
#   --no-mirror          skip the GitHub push mirror even if one is configured
#   --force              push even when the remote repository already has commits
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Global because the EXIT trap that removes it outlives the function that sets
# it. The staged tree holds a Forgejo push URL with a token in .git/config, so
# removing it is not optional tidiness.
STAGING=""
cleanup_staging() { [[ -n "$STAGING" ]] && rm -rf "$STAGING"; }

parse_env_arg "$@"
if [[ ${#ARGS[@]} -gt 0 ]]; then set -- "${ARGS[@]}"; else set --; fi

STAGE_ONLY=""
NO_MIRROR=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-only) STAGE_ONLY="${2:-}"; shift 2 ;;
        --no-mirror)  NO_MIRROR=true; shift ;;
        --force)      FORCE=true; shift ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

setup_paths
parse_config

CLOUD="$(env_cloud)"

# Mirror credentials live with the other values tofu cannot produce.
MANUAL_SECRETS_FILE="${SCRIPT_ENV_DIR}/manual-secrets.env"
[[ -f "$MANUAL_SECRETS_FILE" ]] && { set -a; source "$MANUAL_SECRETS_FILE"; set +a; }

# =============================================================================
# What ships
# =============================================================================
#
# Kept as explicit lists rather than an exclude-everything-else rule: a new
# top-level directory should have to be classified deliberately, not inherit a
# default that quietly publishes it.

# Whole directories, copied as-is.
SHIPPED_DIRS=(
    "k8s/base"
    "k8s/argocd"
    "k8s/templates"
    "k8s/scripts/lib"
)

# Individual files.
SHIPPED_FILES=(
    "renovate.json"
    "k8s/docs/OPERATIONS.md"
    "k8s/docs/KEYCLOAK_SSO.md"
    "k8s/docs/SSO_TESTING_GUIDE.md"
)

# Scripts that set an environment up rather than operate one. They stay behind.
INSTALLER_ONLY_SCRIPTS=(
    "quickstart.sh"
    "setup-env.sh"
    "preflight.sh"
    "setup-gitops-repo.sh"
)

# Files that must never appear in a published repository, matched by basename.
# The staged tree is checked against these *and* scanned for key material, so a
# future addition to SHIPPED_DIRS cannot leak credentials silently.
FORBIDDEN_BASENAMES=(
    "kubeconfig"
    "secrets.env"
    "manual-secrets.env"
    "tofu-outputs.env"
    "oidc-secrets.env"
    "vault-init-keys.json"
    "tls-secret.yaml"
    "terraform.tfstate"
)

# =============================================================================
# Staging
# =============================================================================

stage_repo() {
    local dest="$1"

    log_step "Staging the environment repository..."

    mkdir -p "$dest"

    local d
    for d in "${SHIPPED_DIRS[@]}"; do
        [[ -d "${REPO_ROOT}/${d}" ]] || continue
        mkdir -p "${dest}/$(dirname "$d")"
        cp -r "${REPO_ROOT}/${d}" "${dest}/${d}"
    done

    local f
    for f in "${SHIPPED_FILES[@]}"; do
        [[ -f "${REPO_ROOT}/${f}" ]] || continue
        mkdir -p "${dest}/$(dirname "$f")"
        cp "${REPO_ROOT}/${f}" "${dest}/${f}"
    done

    # Operating scripts, minus the installer-only ones.
    mkdir -p "${dest}/k8s/scripts"
    local script base skip
    for script in "${REPO_ROOT}"/k8s/scripts/*.sh; do
        base="$(basename "$script")"
        skip=false
        local installer
        for installer in "${INSTALLER_ONLY_SCRIPTS[@]}"; do
            [[ "$base" == "$installer" ]] && skip=true
        done
        $skip && continue
        cp "$script" "${dest}/k8s/scripts/${base}"
    done

    # The Windows helpers only mean anything for a local environment.
    if [[ "$ENV" == "local" && -d "${REPO_ROOT}/k8s/scripts/windows" ]]; then
        cp -r "${REPO_ROOT}/k8s/scripts/windows" "${dest}/k8s/scripts/windows"
    fi

    # This environment's overlay, with the shared-cloud devops/ symlink resolved
    # into real files. `cp -rL` is what does the dereferencing.
    mkdir -p "${dest}/k8s/overlays"
    cp -rL "${REPO_ROOT}/k8s/overlays/${ENV}" "${dest}/k8s/overlays/${ENV}"

    # In this repo the overlay config.yaml is a sample and the wizard's answers
    # live in the gitignored k8s/scripts/<env>/config.yaml (see cfg_get). The
    # published repo has no wizard and owns its history, so the effective
    # values are baked into its committed config.yaml here.
    local local_cfg="$(setup_root)/${ENV}/config.yaml"
    if [[ -f "$local_cfg" ]]; then
        local staged_cfg="${dest}/k8s/overlays/${ENV}/config.yaml"
        local key val
        for key in domain acmeEmail gitops.repoUrl platformVaultUrl platformLokiUrl; do
            val="$(yaml_get "$local_cfg" "$key")"
            [[ -n "$val" ]] || continue
            case "$key" in
                gitops.repoUrl)
                    sed -i "s|^\([[:space:]]*repoUrl:\).*|\1 ${val}|" "$staged_cfg" ;;
                *)
                    sed -i "s|^${key}:.*|${key}: ${val}|" "$staged_cfg" ;;
            esac
        done
    fi

    # Generated locally and holding a private key — never publish it. deploy.sh
    # recreates it from k8s/certs on the machine that owns the CA.
    rm -f "${dest}/k8s/overlays/${ENV}/tls-secret.yaml"

    # The cloud's setup guide, and only that cloud's.
    local doc
    if [[ "$ENV" == "local" ]]; then
        doc="LOCAL_SETUP.md"
    else
        doc="$(echo "$CLOUD" | tr '[:lower:]' '[:upper:]')_SETUP.md"
    fi
    [[ -f "${REPO_ROOT}/k8s/docs/${doc}" ]] && cp "${REPO_ROOT}/k8s/docs/${doc}" "${dest}/k8s/docs/${doc}"

    # Infrastructure: this cloud's module and this environment's root module.
    if [[ "$CLOUD" != "local" ]]; then
        local tier="${ENV##*-}"
        mkdir -p "${dest}/tofu/${CLOUD}"
        cp -r "${REPO_ROOT}/tofu/${CLOUD}/modules" "${dest}/tofu/${CLOUD}/modules"
        cp -r "${REPO_ROOT}/tofu/${CLOUD}/${tier}" "${dest}/tofu/${CLOUD}/${tier}"
        [[ -d "${REPO_ROOT}/tofu/scripts" ]] && cp -r "${REPO_ROOT}/tofu/scripts" "${dest}/tofu/scripts"

        # The provider cache and any local state came along with the directory
        # copy. Both are gitignored here for good reason: .terraform is hundreds
        # of megabytes of re-downloadable binaries, and a local tfstate holds
        # database passwords in clear text. .terraform.lock.hcl stays — pinned
        # provider checksums are exactly what a standalone repo needs.
        find "${dest}/tofu" -type d -name ".terraform" -prune -exec rm -rf {} + 2>/dev/null || true
        find "${dest}/tofu" -type f \( -name "*.tfstate" -o -name "*.tfstate.*" \) -delete 2>/dev/null || true

        # backend.hcl and terraform.tfvars are gitignored here and committed
        # there — see the header. Without them `tofu init` cannot run.
        local tofu_src="${REPO_ROOT}/tofu/${CLOUD}/${tier}"
        local tofu_dst="${dest}/tofu/${CLOUD}/${tier}"
        if [[ -f "${tofu_src}/backend.hcl" ]]; then
            cp "${tofu_src}/backend.hcl" "${tofu_dst}/backend.hcl"
        else
            log_warn "No backend.hcl for ${ENV} — the published repo cannot 'tofu init' as-is"
        fi
        [[ -f "${tofu_src}/terraform.tfvars" ]] && cp "${tofu_src}/terraform.tfvars" "${tofu_dst}/terraform.tfvars"
    fi

    render_env_placeholders "$dest"

    write_env_gitignore "$dest"
    write_origin_stamp "$dest"
    write_env_readme "$dest"

    log_info "Staged $(find "$dest" -type f | wc -l) files"
}

# Resolve every ${VAR} in the staged manifests to this environment's value.
#
# In *this* repository a values file may carry ${DOMAIN}: deploy.sh renders it
# through template_values() before handing it to Helm. ArgoCD does no such thing
# — it reads the file from git and passes it to Helm verbatim, so a placeholder
# that survives into the published repo reaches the workload as the literal
# string. That is not a sync error; the component installs and then misbehaves
# (Homepage answered every request with "Host validation failed" because
# HOMEPAGE_ALLOWED_HOSTS was the seven characters ${DOMAIN}).
#
# So the published repo holds no placeholders. It describes one environment and
# already commits backend.hcl and *.tfvars, so a concrete domain is in keeping
# with the rest of it. Only TEMPLATE_VARS are substituted — all non-secret
# (hostnames, buckets, ARNs, identity IDs) — which is why this can be committed;
# unknown placeholders such as ArgoCD's own $oidc.keycloak.clientSecret are left
# alone.
render_env_placeholders() {
    local dest="$1"

    log_step "Resolving \${VAR} placeholders for ${ENV}..."

    # Substituting only the variables that actually have a value, rather than all
    # of TEMPLATE_VARS: envsubst renders an unset variable as the empty string,
    # which turns `url: ${PLATFORM_VAULT_URL}` into `url: ""` — a component that
    # starts and then cannot reach anything, with nothing left in the file to say
    # why. A base manifest legitimately names variables only one cloud or tier
    # sets (the workload bases do), so those keep their placeholder and are
    # reported instead.
    local set_vars="" placeholder name
    for placeholder in $TEMPLATE_VARS; do
        name="${placeholder#\$\{}"
        name="${name%\}}"
        [[ -n "${!name:-}" ]] && set_vars="${set_vars}${placeholder} "
    done

    local file rendered=0
    local -a left=()

    while IFS= read -r file; do
        grep -q '\${' "$file" || continue

        envsubst "$set_vars" < "$file" > "${file}.rendered"
        mv "${file}.rendered" "$file"
        rendered=$((rendered + 1))

        for placeholder in $(grep -o '\${[A-Z_][A-Z0-9_]*}' "$file" | sort -u); do
            [[ "$TEMPLATE_VARS" == *"$placeholder"* ]] || continue
            left+=("${placeholder} → ${file#"${dest}/"}")
        done
    done < <(find "${dest}/k8s" -type f \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null)

    local entry
    for entry in "${left[@]}"; do
        log_warn "No value for this environment, placeholder kept: ${entry}"
    done

    log_info "Rendered ${rendered} manifest(s)"
}

# The environment repo's .gitignore is not this repository's. Two entries are
# deliberately absent: backend.hcl and *.tfvars have to be committed for the
# environment to be operable by someone who never had this checkout.
write_env_gitignore() {
    cat > "${1}/.gitignore" <<'EOF'
# Environment repository .gitignore
#
# Note what is NOT here: backend.hcl and *.tfvars are committed on purpose. They
# hold state bucket names, allowed API CIDRs and admin group IDs — account
# specific, not secret — and without them nobody can `tofu init` this
# environment. Real credentials live in Vault and in the ignored files below.

# OpenTofu state and providers. .terraform.lock.hcl IS committed: provider
# checksums must be identical for every apply.
*.tfstate
*.tfstate.*
.terraform/

# Generated per-environment credentials: kubeconfig, tofu-outputs.env,
# secrets.env, manual-secrets.env, vault-init-keys.json, oidc-secrets.env.
k8s/scripts/*/
!k8s/scripts/lib/
!k8s/scripts/windows/

# Locally generated TLS material (local-ca environments).
k8s/certs/
k8s/overlays/*/tls-secret.yaml

# Editor / OS
*.swp
*.swo
*~
.vscode/
.idea/
.DS_Store
Thumbs.db

# Claude Code: machine-local state. Shared config (.claude/settings.json,
# commands/, skills/) is deliberately not ignored — commit it if it appears.
.claude/worktrees/
.claude/settings.local.json
EOF
}

# Provenance, not a dependency. Nothing reads this file; it exists so that in two
# years "what generated this, and from which commit" is a `cat` rather than
# archaeology.
write_origin_stamp() {
    local sha tag
    sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    tag="$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || echo unknown)"

    cat > "${1}/.devhub-origin" <<EOF
# Generated by devhub. This file is provenance only — nothing reads it, and this
# repository has no further dependency on devhub.
generator: devhub
version: ${tag}
commit: ${sha}
environment: ${ENV}
cloud: ${CLOUD}
generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

write_env_readme() {
    cat > "${1}/README.md" <<EOF
# ${ENV}

The GitOps repository for the **${ENV}** environment (${CLOUD}). ArgoCD on this
environment's cluster reconciles the platform from this repository — it is the
source of truth, and a manual \`helm upgrade\` is reverted by self-heal.

Generated by devhub and then cut loose: there is no upstream to pull from and no
upgrade path back. This repository is now maintained on its own terms. See
\`.devhub-origin\` for which version produced it.

## Layout

| Path | Contents |
|------|----------|
| \`k8s/base/\` | per-component Helm values and manifests |
| \`k8s/overlays/${ENV}/\` | this environment's config.yaml and value overrides |
| \`k8s/argocd/\` | app-of-apps, AppProjects, the platform ApplicationSet |
| \`k8s/scripts/\` | deploy and day-two scripts |
$([[ "$CLOUD" != "local" ]] && echo "| \`tofu/${CLOUD}/\` | infrastructure: cluster, data services, IAM |")

## Day two

\`\`\`bash
cd k8s/scripts
./deploy.sh --env ${ENV} all status      # what is running
./deploy.sh --env ${ENV} <component>     # bootstrap components (ArgoCD owns the rest)
./setup-vault.sh --env ${ENV} status
\`\`\`

Everything ArgoCD owns changes through a commit here, not through a script.
Full procedures — backups, restore, rotation, access — are in
\`k8s/docs/OPERATIONS.md\`.

## Chart updates

\`renovate.json\` ships with this repository so chart pins keep moving after the
link to devhub was cut. Point Renovate at this repository, or bump the pins by
hand in \`k8s/scripts/deploy.sh\` and \`k8s/argocd/platform-appset.yaml\`.
EOF
}

# =============================================================================
# Safety
# =============================================================================
#
# This repository inverts its own .gitignore for backend.hcl and *.tfvars, and
# copies whole directory trees. Both are reasonable; together they are exactly
# how a credential ends up published. So the staged tree is checked before any
# commit exists, and the script refuses rather than warns.
scan_for_secrets() {
    local dest="$1"
    local findings=0 file base forbidden

    while IFS= read -r -d '' file; do
        base="$(basename "$file")"
        for forbidden in "${FORBIDDEN_BASENAMES[@]}"; do
            if [[ "$base" == "$forbidden" ]]; then
                log_error "Refusing to publish ${file#"${dest}/"} (forbidden filename)"
                findings=$((findings + 1))
            fi
        done
    done < <(find "$dest" -type f -print0)

    # Key material, whatever the file is called. The base64 body of a Kubernetes
    # TLS Secret decodes to the same PEM header, so check for both forms.
    while IFS= read -r file; do
        log_error "Refusing to publish ${file#"${dest}/"} (contains a private key)"
        findings=$((findings + 1))
    done < <(grep -rlE -- "-----BEGIN [A-Z ]*PRIVATE KEY-----|LS0tLS1CRUdJTiBQUklWQVRFIEtFWS" "$dest" 2>/dev/null || true)

    if [[ $findings -gt 0 ]]; then
        log_error ""
        log_error "${findings} problem(s) found — nothing was published."
        log_error "Fix the staging rules in setup-gitops-repo.sh before retrying."
        exit 1
    fi

    log_info "Secret scan clean"
}

# =============================================================================
# Forgejo
# =============================================================================

FORGEJO_POD=""
FORGEJO_USER=""

forgejo_pod() {
    if [[ -z "$FORGEJO_POD" ]]; then
        FORGEJO_POD="$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
    fi
    [[ -n "$FORGEJO_POD" ]]
}

# Tokens are minted per run and scoped to what that run needs. The API calls all
# go to localhost:3000 from inside the pod, which sidesteps the gateway, DNS and
# TLS entirely — the same approach configure_woodpecker_oauth uses.
forgejo_token() {
    local name="$1" scopes="$2"
    kubectl exec -n forgejo "$FORGEJO_POD" -- forgejo admin user generate-access-token \
        --username "$FORGEJO_USER" --token-name "${name}-$(date +%s)" \
        --scopes "$scopes" --raw 2>/dev/null | tr -d '\r' | tail -1
}

forgejo_api() {
    local method="$1" path="$2" token="$3" body="${4:-}"
    if [[ -n "$body" ]]; then
        kubectl exec -n forgejo "$FORGEJO_POD" -- curl -sS -X "$method" \
            "http://localhost:3000/api/v1${path}" \
            -H "Authorization: token ${token}" \
            -H "Content-Type: application/json" \
            -d "$body" 2>/dev/null || true
    else
        kubectl exec -n forgejo "$FORGEJO_POD" -- curl -sS -X "$method" \
            "http://localhost:3000/api/v1${path}" \
            -H "Authorization: token ${token}" 2>/dev/null || true
    fi
}

# =============================================================================
# Publish
# =============================================================================

main() {
    log_phase "Publishing the GitOps repository for ${ENV}"

    if [[ -z "${GITOPS_REPO_URL:-}" ]]; then
        log_error "gitops.repoUrl is not set — run './devhub setup --env ${ENV}' (or set it in ${OVERLAY_DIR}/config.yaml)"
        exit 1
    fi

    # https://git.example.com/<org>/<repo>.git
    local path org repo
    path="${GITOPS_REPO_URL#*://}"
    path="${path#*/}"
    org="${path%%/*}"
    repo="${path##*/}"
    repo="${repo%.git}"

    if [[ -z "$org" || -z "$repo" || "$org" == "$path" ]]; then
        log_error "Cannot read <org>/<repo> from gitops.repoUrl: ${GITOPS_REPO_URL}"
        log_error "Expected the form https://git.<domain>/<org>/<repo>.git"
        exit 1
    fi

    log_info "Target: ${org}/${repo} at ${GITOPS_REPO_URL}"

    # ── Stage ────────────────────────────────────────────────────────
    local staging
    if [[ -n "$STAGE_ONLY" ]]; then
        staging="$STAGE_ONLY"
        [[ -e "$staging" ]] && { log_error "${staging} already exists"; exit 1; }
    else
        staging="$(mktemp -d)"
        STAGING="$staging"
        trap cleanup_staging EXIT
    fi

    stage_repo "$staging"
    scan_for_secrets "$staging"

    if [[ -n "$STAGE_ONLY" ]]; then
        echo ""
        log_info "Staged at: ${staging}"
        log_info "Nothing was published. Review it, then re-run without --stage-only."
        return 0
    fi

    # ── Commit ───────────────────────────────────────────────────────
    log_step "Creating the initial commit..."
    git -C "$staging" init -q -b main
    git -C "$staging" add -A
    git -C "$staging" \
        -c user.name="devhub" \
        -c user.email="devhub@localhost" \
        commit -q -m "Initial ${ENV} environment

Generated by devhub from $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown).
This environment is standalone from here on: no upstream, no upgrade path back.
See .devhub-origin for provenance."
    log_info "Committed $(git -C "$staging" rev-list --count HEAD) revision"

    # ── Forgejo: org + repository ────────────────────────────────────
    use_env_kubeconfig
    require_cluster_match

    if ! forgejo_pod; then
        log_error "Forgejo is not running — it hosts the repository this creates."
        log_error "  ./devhub deploy --env ${ENV} forgejo"
        exit 1
    fi

    FORGEJO_USER="$(kubectl get secret forgejo-admin-secret -n forgejo \
        -o jsonpath='{.data.username}' | base64 -d)"

    log_step "Creating ${org}/${repo} in Forgejo..."
    local admin_token
    admin_token="$(forgejo_token "gitops-repo" "write:organization,write:repository,write:user")"
    if [[ -z "$admin_token" ]]; then
        log_error "Could not mint a Forgejo admin token"
        exit 1
    fi

    if [[ -z "$(forgejo_api GET "/orgs/${org}" "$admin_token" | jq -r '.id // empty' 2>/dev/null)" ]]; then
        forgejo_api POST "/orgs" "$admin_token" "{\"username\":\"${org}\"}" >/dev/null
        log_info "Organisation created: ${org}"
    else
        log_info "Organisation exists: ${org}"
    fi

    local existing
    existing="$(forgejo_api GET "/repos/${org}/${repo}" "$admin_token" | jq -r '.id // empty' 2>/dev/null)"
    if [[ -z "$existing" ]]; then
        # Private by default: the repository names every hostname, bucket and
        # CIDR the environment uses.
        forgejo_api POST "/orgs/${org}/repos" "$admin_token" \
            "{\"name\":\"${repo}\",\"private\":true,\"auto_init\":false}" >/dev/null
        log_info "Repository created: ${org}/${repo} (private)"
    else
        log_info "Repository exists: ${org}/${repo}"

        # Count branches rather than trusting the repository's `empty` flag —
        # Forgejo does not always clear it after the first push, and a stale
        # `empty: true` would let this force a published environment back to a
        # generated initial commit.
        local branches
        branches="$(forgejo_api GET "/repos/${org}/${repo}/branches" "$admin_token" \
            | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || echo 0)"
        if [[ "${branches:-0}" -gt 0 && "$FORCE" != true ]]; then
            log_error "${org}/${repo} already has commits — ${ENV} has been published."
            log_error ""
            log_error "This environment is standalone: its repository is the source of truth,"
            log_error "and republishing from devhub would discard whatever it has become."
            log_error "Work in the environment repository instead:"
            log_error "  git clone ${GITOPS_REPO_URL}"
            log_error ""
            log_error "Re-run with --force only to overwrite a disposable environment."
            exit 1
        fi
    fi

    # ── Push ─────────────────────────────────────────────────────────
    log_step "Pushing..."

    # A local-CA environment serves git over a certificate the system store does
    # not know, so point git at the CA rather than disabling verification.
    local -a git_env=()
    if [[ "$TLS_TYPE" == "local-ca" && -f "${CERTS_DIR}/ca/ca.crt" ]]; then
        git_env=(env "GIT_SSL_CAINFO=${CERTS_DIR}/ca/ca.crt")
        log_info "Trusting the local CA for this push"
    fi

    # Credentials go in the URL of a throwaway staging clone, which is deleted on
    # exit — never in a persisted remote.
    local push_url="${GITOPS_REPO_URL#https://}"
    push_url="https://${FORGEJO_USER}:${admin_token}@${push_url}"

    local push_args=(push -q "$push_url" main)
    $FORCE && push_args=(push -q --force "$push_url" main)

    if ! "${git_env[@]+"${git_env[@]}"}" git -C "$staging" "${push_args[@]}"; then
        log_error "Push failed. Is ${GITOPS_REPO_URL%/*} reachable from this machine?"
        exit 1
    fi
    log_info "Pushed to ${GITOPS_REPO_URL}"

    configure_push_mirror "$org" "$repo" "$admin_token"
    register_with_argocd "$org" "$repo"

    echo ""
    log_info "${ENV} now reconciles from its own repository."
    log_info "devhub is no longer part of this environment — clone ${GITOPS_REPO_URL} to work on it."
}

# The off-cluster copy. Forgejo pushes to it on every commit, so the mirror is
# seconds behind rather than hours — but it carries git refs only. Issues, pull
# requests, packages and registry blobs live on Forgejo's PVC and are Velero's
# job (see k8s/docs/OPERATIONS.md).
configure_push_mirror() {
    local org="$1" repo="$2" token="$3"

    if $NO_MIRROR; then
        log_info "Push mirror skipped (--no-mirror)"
        return 0
    fi

    if [[ -z "${GITOPS_MIRROR_URL:-}" || -z "${GITOPS_MIRROR_TOKEN:-}" ]]; then
        log_warn "No off-cluster mirror configured — the GitOps repository exists"
        log_warn "only inside the cluster it manages. Set these in"
        log_warn "  ${MANUAL_SECRETS_FILE#"${REPO_ROOT}/"}"
        log_warn "  GITOPS_MIRROR_URL=https://github.com/<org>/<repo>.git"
        log_warn "  GITOPS_MIRROR_TOKEN=<personal access token with repo scope>"
        return 0
    fi

    log_step "Configuring the push mirror to ${GITOPS_MIRROR_URL}..."

    local existing
    existing="$(forgejo_api GET "/repos/${org}/${repo}/push_mirrors" "$token" \
        | jq -r --arg u "$GITOPS_MIRROR_URL" '.[]? | select(.remote_address == $u) | .remote_name' 2>/dev/null)"
    if [[ -n "$existing" ]]; then
        log_info "Push mirror already configured"
        return 0
    fi

    local body
    body="$(jq -nc \
        --arg addr "$GITOPS_MIRROR_URL" \
        --arg user "${GITOPS_MIRROR_USER:-git}" \
        --arg pass "$GITOPS_MIRROR_TOKEN" \
        '{remote_address:$addr, remote_username:$user, remote_password:$pass,
          interval:"8h0m0s", sync_on_commit:true}')"

    if [[ -n "$(forgejo_api POST "/repos/${org}/${repo}/push_mirrors" "$token" "$body" \
                | jq -r '.remote_address // empty' 2>/dev/null)" ]]; then
        log_info "Push mirror configured (syncs on every commit)"
        log_warn "The mirror force-overwrites the remote — never commit there directly."
    else
        log_warn "Forgejo did not accept the push mirror; add it by hand:"
        log_warn "  Forgejo → ${org}/${repo} → Settings → Mirror Settings"
    fi
}

# ArgoCD reads the repository with its own read-only token rather than the admin
# token used above, so revoking one does not break the other.
register_with_argocd() {
    local org="$1" repo="$2"

    log_step "Registering the repository with ArgoCD..."

    local ro_token
    ro_token="$(forgejo_token "argocd" "read:repository")"
    if [[ -z "$ro_token" ]]; then
        log_warn "Could not mint a read-only token — register the repo by hand:"
        log_warn "  argocd repo add ${GITOPS_REPO_URL} --username <user> --password <token>"
        return 0
    fi

    # The URL must match what platform-appset.yaml and app-of-apps.yaml resolve
    # to, or ArgoCD looks up credentials for a repository it never clones. On
    # local that is Forgejo's in-cluster Service; elsewhere the two are equal.
    kubectl create secret generic "repo-${ENV}" -n argocd \
        --from-literal=type=git \
        --from-literal=url="$GITOPS_REPO_URL_INTERNAL" \
        --from-literal=username="$FORGEJO_USER" \
        --from-literal=password="$ro_token" \
        --dry-run=client -o yaml \
        | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
        | kubectl apply -f - >/dev/null

    log_info "ArgoCD credentials stored (secret repo-${ENV} in argocd)"
    [[ "$GITOPS_REPO_URL_INTERNAL" != "$GITOPS_REPO_URL" ]] && \
        log_info "ArgoCD clones ${GITOPS_REPO_URL_INTERNAL} (in-cluster); you clone ${GITOPS_REPO_URL}"

    # The developer-apps ApplicationSet (k8s/argocd/apps/forgejo-appset.yaml)
    # enumerates repositories in the organisation through Forgejo's Gitea API,
    # which needs its own token. Without it the ApplicationSet reports
    # ParametersGenerated=False and no application is ever discovered — a failure
    # that only surfaces once ArgoCD can read the repository at all.
    local scm_token
    # read:issue looks gratuitous for listing repositories, but Forgejo's
    # /repos/search — the call ArgoCD's Gitea SCM provider makes — rejects a token
    # without it: "token does not have at least one of required scope(s)".
    scm_token="$(forgejo_token "argocd-scm" "read:repository,read:organization,read:issue")"
    if [[ -n "$scm_token" ]]; then
        kubectl create secret generic argocd-forgejo-scm-token -n argocd \
            --from-literal=token="$scm_token" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        log_info "Forgejo SCM token stored (developer apps are discovered from ${org}/*)"
    else
        log_warn "Could not mint the SCM token — developer apps will not be discovered."
        log_warn "Create it by hand: kubectl create secret generic argocd-forgejo-scm-token \\"
        log_warn "  -n argocd --from-literal=token=<forgejo token with read:repository>"
    fi

    # Nudge the Applications rather than waiting out the reconcile interval.
    kubectl annotate applications -n argocd --all \
        argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

main "$@"
