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
#     environment frozen at its birth date rots quietly. A generated
#     platform-config Application is what makes those bumps *take effect*, and a
#     generated .woodpecker.yml is what checks them before they do — without
#     either, Renovate in a published repo is decoration.
#   - k8s/e2e/ ships, because validate-e2e.sh does and is useless without it.
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
# it. Credentials never touch the staged tree (the push authenticates with an
# HTTP header, not a URL), but the tree still names every hostname, bucket and
# CIDR the environment uses — remove it either way.
STAGING=""
cleanup_staging() { [[ -n "$STAGING" ]] && rm -rf "$STAGING"; }

# The publish token is admin-scoped and minted per run; leaving it valid after
# the run is a standing credential nobody tracks. Revoked from the EXIT trap so
# an aborted run cleans up too. Uses basic auth (Forgejo's token endpoints
# refuse token auth), fed to curl over stdin so the password never appears in
# an argv.
ADMIN_TOKEN_NAME=""
revoke_publish_token() {
    [[ -n "$ADMIN_TOKEN_NAME" && -n "$FORGEJO_POD" && -n "$FORGEJO_USER" ]] || return 0
    local pass
    pass="$(kubectl get secret forgejo-admin-secret -n forgejo \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
    [[ -n "$pass" ]] || return 0
    if kubectl exec -i -n forgejo "$FORGEJO_POD" -- curl -sS -o /dev/null -f -K - \
        -X DELETE "http://localhost:3000/api/v1/users/${FORGEJO_USER}/tokens/${ADMIN_TOKEN_NAME}" \
        <<< "user = \"${FORGEJO_USER}:${pass}\"" 2>/dev/null; then
        log_info "Publish token revoked (${ADMIN_TOKEN_NAME})"
    else
        log_warn "Could not revoke the publish token ${ADMIN_TOKEN_NAME} —"
        log_warn "delete it in Forgejo: Settings → Applications → Access tokens"
    fi
    ADMIN_TOKEN_NAME=""
}

cleanup() { revoke_publish_token; cleanup_staging; }

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
#
# CLOUD_CAPABILITIES.md ships because OPERATIONS.md links to it for the gaps an
# operator has to live with (Forgejo on a volume, UpCloud's manual unseal, the
# opt-in cache); ADDONS.md because enabling an add-on is a day-two action, and
# the retrofit it documents is for exactly this kind of handed-over environment.
# k8s/e2e/README.md rides along inside the e2e directory.
SHIPPED_FILES=(
    "renovate.json"
    "k8s/docs/OPERATIONS.md"
    "k8s/docs/KEYCLOAK_SSO.md"
    "k8s/docs/SSO_TESTING_GUIDE.md"
    "k8s/docs/CLOUD_CAPABILITIES.md"
    "k8s/docs/ADDONS.md"
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

    # The end-to-end suite. validate-e2e.sh ships as one of the operating
    # scripts below, and without k8s/e2e/ it has nothing to run: `./devhub
    # validate --e2e` in a published environment failed on a missing
    # playwright.config.js, which reads as "the platform is broken" rather than
    # "the suite was never copied".
    #
    # Copied through tar rather than `cp -r` for the excludes: node_modules is
    # ~75 MB of re-installable binaries, .auth holds a live SSO storage state
    # (a session cookie — a credential), and report/ + results/ are artefacts of
    # whoever ran it last. `npm ci` in the published repo restores the rest
    # (package-lock.json ships if the generating checkout had one).
    if [[ -d "${REPO_ROOT}/k8s/e2e" ]]; then
        mkdir -p "${dest}/k8s/e2e"
        tar -C "${REPO_ROOT}/k8s/e2e" \
            --exclude=./node_modules --exclude=./.auth \
            --exclude=./report --exclude=./results \
            -cf - . | tar -C "${dest}/k8s/e2e" -xf -
    fi

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

    bake_answers_into_config "$dest"

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
        # -L, not -r: the root module's backend.tf, outputs.tf, providers.tf and
        # variables-api-access.tf are symlinks into tofu/<cloud>/shared/, which is
        # dev and prod sharing one copy of the files that were identical in both.
        # Only this tier's directory is published, so a plain copy would land
        # four dangling links and `tofu init` would fail on a root module with no
        # backend. Same reason the overlay's devops/ symlink is dereferenced.
        cp -rL "${REPO_ROOT}/tofu/${CLOUD}/${tier}" "${dest}/tofu/${CLOUD}/${tier}"
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

    write_platform_config_app "$dest"
    write_env_ci "$dest"
    write_env_gitignore "$dest"
    write_origin_stamp "$dest"
    write_env_readme "$dest"

    log_info "Staged $(find "$dest" -type f | wc -l) files"
}

# =============================================================================
# Baking the wizard's answers into the published config.yaml
# =============================================================================
#
# In this repo the overlay config.yaml is a committed sample and the wizard's
# answers live in the gitignored _setup/<env>/config.yaml, layered over it by
# cfg_get. The published repo has no wizard and owns its history, so the
# effective values have to be written into its committed config.yaml.
#
# The set of keys is *derived from the answers file* rather than listed here. A
# hardcoded list (it was `domain acmeEmail gitops.repoUrl platformVaultUrl
# platformLokiUrl`) means every new question setup-env.sh learns to ask silently
# publishes the committed sample value instead of the operator's answer — a
# failure with no error message, discovered when the environment behaves as
# though it were called example.com. Whatever the operator answered ships.

# Every dotted path in a config.yaml that carries a scalar value. Same
# indentation-aware walk as yaml_get in lib/common.sh, so a nested `host:`
# cannot be reported under the wrong parent; mapping openers (no value on the
# line) are not leaves and are skipped.
yaml_leaf_paths() {
    awk '
        {
            line = $0
            sub(/[[:space:]]*#.*$/, "", line)
            if (line ~ /^[[:space:]]*$/) next

            match(line, /^[ ]*/)
            indent = RLENGTH

            if (line !~ /^[ ]*[A-Za-z0-9_.-]+:/) next
            key = line
            sub(/^[ ]*/, "", key)
            val = key
            sub(/^[A-Za-z0-9_.-]+:[ ]*/, "", val)
            sub(/:.*$/, "", key)

            while (depth > 0 && indents[depth] >= indent) depth--
            depth++
            indents[depth] = indent
            keys[depth] = key

            gsub(/^[ \t]+|[ \t]+$/, "", val)
            if (val == "") next

            full = keys[1]
            for (i = 2; i <= depth; i++) full = full "." keys[i]
            print full
        }
    ' "$1"
}

# Replace the scalar at a dotted path, in place, parent-scoped.
#
# The parent scoping is the point. The previous substitution for gitops.repoUrl
# was `sed -i 's|^\([[:space:]]*repoUrl:\).*|...|'`, which rewrites *any* line
# whose key is repoUrl at any indentation under any parent — correct only for as
# long as config.yaml has exactly one of them. Same awk path stack as yaml_get.
#
# The new value goes through the environment rather than `awk -v`, which would
# interpret backslash escapes in a value that is meant to be literal.
# Returns non-zero if the path is not present in the file.
yaml_set_scalar() {
    local file="$1" path="$2" value="$3" tmp
    tmp="$(mktemp)"

    if _YAML_SET_VALUE="$value" awk -v want="$path" '
        {
            raw = $0
            line = raw
            sub(/[[:space:]]*#.*$/, "", line)
            if (line ~ /^[[:space:]]*$/) { print raw; next }

            match(line, /^[ ]*/)
            indent = RLENGTH

            if (line !~ /^[ ]*[A-Za-z0-9_.-]+:/) { print raw; next }
            key = line
            sub(/^[ ]*/, "", key)
            sub(/:.*$/, "", key)

            while (depth > 0 && indents[depth] >= indent) depth--
            depth++
            indents[depth] = indent
            keys[depth] = key

            full = keys[1]
            for (i = 2; i <= depth; i++) full = full "." keys[i]

            if (full == want && !done) {
                printf "%s%s: %s\n", substr(raw, 1, indent), key, ENVIRON["_YAML_SET_VALUE"]
                done = 1
                next
            }
            print raw
        }
        END { exit(done ? 0 : 1) }
    ' "$file" > "$tmp"; then
        mv "$tmp" "$file"
        return 0
    fi

    rm -f "$tmp"
    return 1
}

bake_answers_into_config() {
    local dest="$1"
    local answers="$(setup_root)/${ENV}/config.yaml"
    local staged="${dest}/k8s/overlays/${ENV}/config.yaml"

    [[ -f "$answers" && -f "$staged" ]] || return 0

    local key val baked=0
    while IFS= read -r key; do
        val="$(yaml_get "$answers" "$key")"
        [[ -n "$val" ]] || continue
        if yaml_set_scalar "$staged" "$key" "$val"; then
            baked=$((baked + 1))
        else
            # The answers file knows a key the committed overlay does not
            # declare. Appending it blindly would guess at the nesting, so say
            # so instead — the published environment would otherwise run on the
            # sample value with nothing to point at.
            log_warn "Answered '${key}' has no place in overlays/${ENV}/config.yaml — not baked"
            log_warn "  add the key to the committed overlay so it can be published"
        fi
    done < <(yaml_leaf_paths "$answers")

    log_info "Baked ${baked} answered value(s) into the published config.yaml"
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

# =============================================================================
# platform-config: the Application that makes chart-pin commits take effect
# =============================================================================
#
# Without this, Renovate is decorative after the handover.
#
# In the published repo the app-of-apps (k8s/argocd/apps/app-of-apps.yaml)
# watches k8s/argocd/apps with recurse: false, so the only things any controller
# reconciles are the Applications in that one directory. platform-appset.yaml
# and projects/ sit one level up and are applied by `deploy.sh <env> gitops` —
# imperatively, once. A merged Renovate PR that bumps a chart version in
# platform-appset.yaml therefore changes a file nobody reads: the ApplicationSet
# object in the cluster keeps the old pin, the platform keeps the old chart, and
# the git history says otherwise. That is the worst kind of drift, because it
# looks like it worked.
#
# So the published repo gets one more Application whose source is its own
# k8s/argocd directory, filtered to the two things deploy.sh would otherwise own
# alone. After this, `git commit` on a chart pin is the whole update procedure.
#
# Why only here and not in devhub itself: in *this* repository platform-appset.yaml
# carries ${GITOPS_REPO_URL_INTERNAL} / ${GITOPS_REVISION} / ${ENV}, which
# deploy.sh resolves through template_values() before applying. ArgoCD does no
# templating — it hands the file to the cluster verbatim — so pointing an
# Application at it upstream would apply an ApplicationSet whose repoURL is the
# literal seven characters ${ENV}. render_env_placeholders has already resolved
# them in the staged tree, which is what makes this safe; the check below is that
# guarantee made explicit rather than assumed.
#
# projects/*.yaml is already placeholder-free by design — deploy.sh applies those
# verbatim with no template_values() pass, so they use repo-URL prefix globs
# rather than ${GITOPS_REPO_URL_INTERNAL}. The check covers them anyway: it
# should fail if that ever stops being true.
write_platform_config_app() {
    local dest="$1"
    local argocd_dir="${dest}/k8s/argocd"

    [[ -f "${argocd_dir}/platform-appset.yaml" ]] || return 0

    log_step "Generating the platform-config Application..."

    # Placeholder-free, or nothing. A single surviving ${VAR} here would be
    # applied to the cluster as text.
    local leftover
    leftover="$({ grep -rhoE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' \
        "${argocd_dir}/platform-appset.yaml" "${argocd_dir}/projects/" 2>/dev/null \
        || true; } | sort -u | tr '\n' ' ')"
    if [[ -n "$leftover" ]]; then
        log_error "Unresolved placeholder(s) in the staged k8s/argocd tree: ${leftover}"
        log_error ""
        log_error "ArgoCD does not template manifests — it would apply these literally."
        log_error "Every variable used by platform-appset.yaml and projects/ must be in"
        log_error "TEMPLATE_VARS (lib/common.sh) *and* have a value for ${ENV}; check"
        log_error "_setup/${ENV}/tofu-outputs.env and the placeholder warnings above."
        exit 1
    fi

    cat > "${argocd_dir}/apps/platform-config.yaml" <<EOF
# platform-config — reconciles this repository's own ArgoCD configuration.
#
# Generated by devhub when this environment was published. It is what makes a
# commit to platform-appset.yaml or projects/ actually happen: without it those
# files are applied only by \`deploy.sh --env ${ENV} gitops\`, so a merged
# Renovate chart-pin bump would change git and nothing else.
#
# Picked up automatically: the app-of-apps watches this directory.
#
# prune: false — deliberately. This Application manages the ApplicationSet that
# owns every GitOps platform component. A path typo or a bad include pattern
# that made the manifests "disappear" must not be able to delete cert-manager,
# the monitoring stack and Velero along with it. Removing a component is an
# edit to platform-appset.yaml, whose own prune rules then apply.
#
# No finalizer, for the same reason: deleting this Application should hand
# control back to deploy.sh, not cascade into the platform.
#
# recurse: true is required — with recurse: false ArgoCD never descends into
# projects/, so the include pattern below would match nothing there. The
# include is also what keeps this Application from picking up apps/ (including
# itself) and looping.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-config
  namespace: argocd
spec:
  # 'default', not the 'platform' AppProject the other platform Applications
  # use: this is the Application that installs projects/platform.yaml, so it
  # must not depend on that object existing. An Application naming a missing
  # project is rejected outright — which would make a deleted AppProject
  # unrecoverable through GitOps.
  project: default

  source:
    repoURL: ${GITOPS_REPO_URL_INTERNAL}
    targetRevision: ${GITOPS_REVISION}
    path: k8s/argocd
    directory:
      recurse: true
      include: '{platform-appset.yaml,projects/*.yaml}'

  destination:
    server: https://kubernetes.default.svc
    namespace: argocd

  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      # The ApplicationSet manifest is large and hand-edited; a client-side
      # apply would drop fields it did not send.
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF

    log_info "platform-config Application generated (appset + projects now reconcile from git)"
}

# =============================================================================
# CI for the published repository
# =============================================================================
#
# The published repo is where platform changes are now made, and it is the one
# place with no rehearsal: a single environment, ArgoCD syncing automatically
# with selfHeal, and no staging copy to try a chart bump against. Until now it
# also ran no checks at all — devhub's own .github/workflows/validate.yml is
# installer-only and does not ship (there is no GitHub Actions runner in an
# environment), and nothing generated a Woodpecker pipeline. So a Renovate PR
# that bumps a chart whose values schema changed merged green and reached the
# running platform.
#
# This is the same static validation CI runs upstream, pointed at the one
# environment this repo describes. It answers "would this deploy?" — not "does
# the deployed thing work?", which is validate-e2e.sh against the live cluster.
write_env_ci() {
    local dest="$1"

    cat > "${dest}/.woodpecker.yml" <<EOF
# Woodpecker CI — ${ENV} platform repository
#
# Runs the same static validation devhub's own CI runs: YAML parses and has no
# duplicate keys, config.yaml has the keys the scripts read, every
# \${PLACEHOLDER} is in the envsubst allow-list, the base/overlay pairs the
# platform ApplicationSet references exist, and every chart still renders.
#
# Why this file exists: ArgoCD syncs this repository automatically with
# selfHeal, so a merge lands on the running platform with no further step. A
# single-environment repo has nowhere to rehearse, which makes the pull request
# the only gate there is.
#
# Activate the repository in Woodpecker once (https://ci.\${DOMAIN} → add
# repository) or nothing here ever runs. Consider requiring the check on the
# default branch too, so a Renovate PR cannot merge red.
#
# Steps run as unprivileged pods on the tainted CI node pool; a Kyverno
# mutation adds the nodeSelector and toleration.

when:
  - event: [push, pull_request]

steps:
  # No cluster, no cloud credentials, no network beyond apk: this step is the
  # one that must always be green.
  #
  # findutils: validate-overlays.sh discovers environments with \`find -printf\`,
  # which busybox find does not implement. Not reached while the env is named
  # explicitly below, but one \`--helm\` invocation without it is enough.
  # gettext supplies envsubst, py3-yaml the duplicate-key parser.
  - name: validate
    image: alpine:3.21
    commands:
      - apk add --no-cache bash python3 py3-yaml gettext findutils
      - bash k8s/scripts/validate-overlays.sh ${ENV}

  # Renders every chart with this environment's values. Separate step because it
  # needs the network (chart repositories) and is therefore the one that can
  # fail for reasons that are not this commit's fault — a major chart bump whose
  # values schema moved fails precisely here, which is the point.
  #
  # The repository list mirrors the chart pins in k8s/scripts/deploy.sh: a new
  # platform component from a new chart repository needs a line added.
  - name: validate-helm
    image: alpine:3.21
    commands:
      - apk add --no-cache bash python3 py3-yaml gettext findutils helm
      - helm repo add jetstack https://charts.jetstack.io
      - helm repo add hashicorp https://helm.releases.hashicorp.com
      - helm repo add external-secrets https://charts.external-secrets.io
      - helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
      - helm repo add grafana https://grafana.github.io/helm-charts
      - helm repo add argo https://argoproj.github.io/argo-helm
      - helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
      - helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
      - helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
      - helm repo add woodpecker https://woodpecker-ci.org/
      - helm repo add kyverno https://kyverno.github.io/kyverno
      - helm repo add stakater https://stakater.github.io/stakater-charts
      - helm repo add jameswynn https://jameswynn.github.io/helm-charts
      - helm repo update
      - bash k8s/scripts/validate-overlays.sh --helm ${ENV}
EOF

    log_info "Generated .woodpecker.yml (validate-overlays on push and pull_request)"
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

# End-to-end suite: installed dependencies and run artefacts. k8s/e2e/.auth
# holds a signed-in browser storage state — a live session cookie.
k8s/e2e/node_modules/
k8s/e2e/.auth/
k8s/e2e/report/
k8s/e2e/results/

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
| \`k8s/e2e/\` | Playwright end-to-end checks against this live environment |
| \`.woodpecker.yml\` | CI: static validation on every push and pull request |
$([[ "$CLOUD" != "local" ]] && echo "| \`tofu/${CLOUD}/\` | infrastructure: cluster, data services, IAM |")

## Day two

\`\`\`bash
cd k8s/scripts
./deploy.sh --env ${ENV} all status      # what is running
./deploy.sh --env ${ENV} <component>     # bootstrap components (ArgoCD owns the rest)
./setup-vault.sh --env ${ENV} status
\`\`\`

Everything ArgoCD owns changes through a commit here, not through a script.
Full procedures — backups, restore, rotation, upgrades, access — are in
\`k8s/docs/OPERATIONS.md\`.

## Checks

\`.woodpecker.yml\` runs the static validation on every push and pull request —
YAML, config keys, placeholders, and \`helm template\` for every component.
Activate this repository in Woodpecker once, or nothing runs and a Renovate pull
request merges unchecked.

\`\`\`bash
cd k8s/e2e && npm ci                     # once
./k8s/scripts/validate-overlays.sh ${ENV}      # would this deploy?
./k8s/scripts/validate-e2e.sh --env ${ENV}     # does what is deployed work?
\`\`\`

## Chart updates

\`renovate.json\` ships with this repository so chart pins keep moving after the
link to devhub was cut. Point Renovate at this repository, or bump the pins by
hand in \`k8s/scripts/deploy.sh\` and \`k8s/argocd/platform-appset.yaml\`.

A bump in \`platform-appset.yaml\` takes effect because of the generated
\`k8s/argocd/apps/platform-config.yaml\` Application: it reconciles the
ApplicationSet and the AppProjects from this repository, so merging is the whole
procedure. Bumps in \`k8s/scripts/deploy.sh\` cover the bootstrap components and
still need \`./deploy.sh --env ${ENV} <component>\` to be run.

Bringing later devhub improvements in is a merge, not an upgrade — the recipe is
in \`k8s/docs/OPERATIONS.md\` ("Keeping the platform up to date").
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

    # Content, not just filenames — for the tofu tree specifically, because this
    # script deliberately inverts .gitignore there and *commits* backend.hcl and
    # *.tfvars. Those two files are gitignored in devhub for a reason: nothing
    # stops an operator from putting a real value where a variable reference
    # belongs (`db_password = "..."` in terraform.tfvars is the obvious one, a
    # Cloudflare API token the next), and the basename and PEM checks above see
    # neither. The published repo is private, but "private repository" is not a
    # secret store: everyone with read access to the environment gets it, the
    # push mirror copies it off-cluster, and git keeps it after the fix.
    #
    # Assignment-shaped only, and the key name has to *end* in the suspicious
    # word — `token_endpoint = "https://..."` is not a credential, `admin_token`
    # is. A right-hand side that is a variable reference (`= var.x`, `= data.x`,
    # `= local.x`) cannot match, because a quoted literal is required; the
    # second grep drops the interpolation-only form `= "${var.x}"` as well.
    # *.example files are excluded by the include globs — their whole job is to
    # show the shape of a value.
    if [[ -d "${dest}/tofu" ]]; then
        local hit
        while IFS= read -r hit; do
            log_error "Refusing to publish ${hit} — that reads as a credential, not configuration"
            findings=$((findings + 1))
        done < <(cd "$dest" && grep -rniE \
                    --include='*.tf' --include='*.tfvars' --include='*.hcl' \
                    --exclude='*.example' \
                    -- '^[^#]*[[:alnum:]_]*(access_key|secret_key|password|passwd|token|client_secret|api_key)[[:space:]]*=[[:space:]]*"[^"]+"' \
                    tofu 2>/dev/null \
                 | grep -vE '=[[:space:]]*"\$\{[^"]*\}"' \
                 | sed -E 's/(=[[:space:]]*").*/\1REDACTED"/' || true)
    fi

    if [[ $findings -gt 0 ]]; then
        log_error ""
        log_error "${findings} problem(s) found — nothing was published."
        log_error "For a filename or a key file: fix the staging rules in this script."
        log_error "For a tofu assignment: the value belongs in Vault or in the gitignored"
        log_error "_setup/${ENV}/manual-secrets.env, and the variable should have no default."
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

# The repository this script creates in Forgejo is private, and deliberately so:
# it names every hostname, bucket and CIDR the environment uses, and it commits
# backend.hcl and *.tfvars. None of that was ever checked for the *mirror*, which
# receives an identical copy — a public GitHub repository is one paste of a URL
# away from publishing the environment's whole topology.
#
# Best effort, and a warning rather than an abort: a 200 could legitimately be an
# authenticated proxy, an enterprise SSO edge that serves a page to everyone, or
# a self-hosted Forgejo/GitLab whose landing page is public while the repository
# is not. A missing answer is not evidence either way. Redirects are deliberately
# not followed: GitLab answers an anonymous request for a private repository with
# a 302 to its sign-in page, and following it would turn every private GitLab
# mirror into a false 200.
check_mirror_visibility() {
    command -v curl >/dev/null 2>&1 || return 0

    local probe="${GITOPS_MIRROR_URL%.git}" code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$probe" 2>/dev/null || echo "")"

    case "$code" in
        200)
            log_warn ""
            log_warn "The mirror target answered 200 to an unauthenticated request:"
            log_warn "  ${probe}"
            log_warn "If that page is the repository, this environment's hostnames, bucket"
            log_warn "names, allowed API CIDRs and admin group IDs are about to be public."
            log_warn "Check, before the first sync:"
            log_warn "  - the repository's visibility is private"
            log_warn "  - the mirror token is scoped to that one repository, not the org"
            log_warn "  - no fork or CI artefact of it is public"
            log_warn "Continuing — a 200 can also be a public landing page in front of a"
            log_warn "private repository, which this check cannot tell apart."
            log_warn ""
            ;;
        ""|000)
            log_info "Mirror visibility not checked (no answer from ${probe})"
            ;;
        *)
            log_info "Mirror target is not readable anonymously (HTTP ${code}) — as expected"
            ;;
    esac
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

    check_mirror_visibility

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
