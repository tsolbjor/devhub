#!/bin/bash
set -uo pipefail

# =============================================================================
# Configuration and Manifest Validation
# =============================================================================
# Static checks that need no cluster and no cloud credentials, so CI can run
# them on every push:
#
#   1. YAML parses, and has no duplicate keys (silent-override bugs)
#   2. Every overlay's config.yaml has the keys the scripts read
#   3. Every ${PLACEHOLDER} in a values/manifest file is in the envsubst
#      allow-list — an unlisted variable is silently left as literal text in the
#      rendered Helm values, which is how "${LOKI_BUCKET}" ends up as a bucket name
#   4. Base/overlay pairs referenced by the platform ApplicationSet exist
#   5. Optional (--helm): `helm template` every component (needs network)
#
# Usage: ./validate-overlays.sh [--helm] [env ...]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

K8S_DIR="${SCRIPT_DIR}/.."
BASE_DIR="${K8S_DIR}/base"
OVERLAYS_DIR="${K8S_DIR}/overlays"

RUN_HELM=false
ENVS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --helm) RUN_HELM=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--helm] [env ...]"
            echo ""
            echo "  --helm   also run 'helm template' for each component (needs network)"
            echo "  env      one or more environments (default: all)"
            exit 0
            ;;
        *) ENVS+=("$1"); shift ;;
    esac
done

if [[ ${#ENVS[@]} -eq 0 ]]; then
    # Every directory under overlays/ that has a config.yaml is an environment.
    while read -r dir; do
        ENVS+=("$(basename "$dir")")
    done < <(find "$OVERLAYS_DIR" -mindepth 2 -maxdepth 2 -name config.yaml -printf '%h\n' | sort)
fi

FAILURES=0
fail() { log_error "$1"; FAILURES=$((FAILURES + 1)); }

# =============================================================================
# 1. YAML parses and has no duplicate keys
# =============================================================================

check_yaml_syntax() {
    log_step "Checking YAML syntax and duplicate keys..."

    if ! command -v python3 &>/dev/null; then
        log_warn "python3 not found — skipping YAML parse checks"
        return 0
    fi

    local bad
    bad="$(python3 - "$K8S_DIR" <<'PY'
import re, sys, pathlib

try:
    import yaml
except ImportError:
    print("SKIP: pyyaml not installed")
    sys.exit(0)


class DupCheckLoader(yaml.SafeLoader):
    """Rejects duplicate mapping keys instead of silently keeping the last one."""


def _no_duplicates(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.YAMLError(f"duplicate key {key!r} at line {key_node.start_mark.line + 1}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


DupCheckLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicates)

root = pathlib.Path(sys.argv[1])
problems = 0
for path in sorted(root.rglob("*.yaml")):
    if any(part in {"certs", ".terraform"} for part in path.parts):
        continue
    # The devhub-app chart's templates are Helm templates, not YAML — control
    # flow ({{- if }}) has no YAML shape even with expressions masked. They are
    # checked by `helm lint`/`helm template` instead (check_devhub_app_chart).
    if "devhub-app-chart" in path.parts and path.parent.name == "templates":
        continue
    text = path.read_text()
    # ArgoCD/Helm templating ({{ .x }}) and Alertmanager's Go templates are not
    # valid YAML on their own; replace each expression with a plain token so the
    # surrounding structure can still be checked.
    text = re.sub(r"\{\{[^{}]*\}\}", "TEMPLATE_EXPR", text)
    try:
        list(yaml.load_all(text, Loader=DupCheckLoader))
    except yaml.YAMLError as exc:
        rel = path.relative_to(root)
        first = str(exc).splitlines()[0]
        print(f"{rel}: {first}")
        problems += 1
sys.exit(1 if problems else 0)
PY
)" || true

    if [[ -n "$bad" ]]; then
        if [[ "$bad" == SKIP:* ]]; then
            log_warn "${bad#SKIP: } — skipping YAML parse checks"
        else
            while read -r line; do
                [[ -n "$line" ]] && fail "YAML: $line"
            done <<< "$bad"
        fi
    else
        log_info "YAML parses cleanly, no duplicate keys"
    fi
}

# =============================================================================
# 2. Required config.yaml keys per environment
# =============================================================================

check_config_keys() {
    local env="$1"
    local config="${OVERLAYS_DIR}/${env}/config.yaml"

    [[ -f "$config" ]] || { fail "${env}: missing config.yaml"; return; }

    local required=(domain tls.type acmeEmail)
    if [[ " ${WORKLOAD_ENVS} " == *" ${env} "* ]]; then
        required+=(platformVaultUrl platformLokiUrl)
    else
        required+=(dataServices.type gitops.repoUrl)
    fi

    local key value
    for key in "${required[@]}"; do
        value="$(yaml_get "$config" "$key")"
        # acmeEmail is legitimately empty for the local CA setup.
        if [[ -z "$value" && ! ( "$env" == "local" && "$key" == "acmeEmail" ) ]]; then
            fail "${env}: config.yaml is missing '${key}'"
        fi
    done

    # A placeholder domain in a cloud environment means someone forgot to edit it.
    local domain
    domain="$(yaml_get "$config" domain)"
    if [[ "$env" != "local" && "$domain" == *example.com ]]; then
        log_warn "${env}: domain is still the placeholder '${domain}'"
    fi
}

# =============================================================================
# 3. Placeholders must be in the envsubst allow-list
# =============================================================================

check_placeholders() {
    log_step "Checking \${...} placeholders against the envsubst allow-list..."

    # Allow-list from common.sh, plus NAMESPACE (deploy-workload.sh substitutes that
    # one with its own envsubst call, per namespace). Adding anything else here
    # hides a real bug: a placeholder outside TEMPLATE_VARS is never substituted,
    # which is how ${GITOPS_REPO_URL} once reached ArgoCD as a literal string.
    local allowed=" $(echo "$TEMPLATE_VARS" | tr -d '${}' | tr '\n' ' ') NAMESPACE "

    local files unknown=0
    files="$(find "$BASE_DIR" "$OVERLAYS_DIR" "${K8S_DIR}/argocd" -name '*.yaml' -type f 2>/dev/null | sort)"

    local file var
    while read -r file; do
        [[ -n "$file" ]] || continue
        # Match ${VAR}; ignore ArgoCD's own $oidc.* style references.
        while read -r var; do
            [[ -n "$var" ]] || continue
            if [[ " $allowed " != *" $var "* ]]; then
                fail "${file#"${K8S_DIR}/"}: \${${var}} is not in the envsubst allow-list (it will not be substituted)"
                unknown=$((unknown + 1))
            fi
        done < <(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "$file" 2>/dev/null | tr -d '${}' | sort -u)
    done <<< "$files"

    [[ $unknown -eq 0 ]] && log_info "All placeholders are substitutable"
}

# =============================================================================
# 4. Values files referenced by the platform ApplicationSet exist
# =============================================================================

check_appset_values() {
    local appset="${K8S_DIR}/argocd/platform-appset.yaml"
    [[ -f "$appset" ]] || return 0

    log_step "Checking platform ApplicationSet value paths..."

    local repo_root="${K8S_DIR}/.."
    local path
    while read -r path; do
        [[ -n "$path" ]] || continue
        if [[ ! -f "${repo_root}/${path}" ]]; then
            fail "platform-appset.yaml references a missing base values file: ${path}"
        fi
    done < <(grep -oE 'baseValues: [^ ]+' "$appset" | awk '{print $2}')

    log_info "ApplicationSet base values resolved"
}

# =============================================================================
# 5. Optional: helm template
# =============================================================================

# Charts legitimately require values that only exist after `tofu apply` (database
# hosts, bucket names, role ARNs). CI has none of those, so stub anything empty —
# the point of this check is that the templates render, not that the values are real.
stub_infra_vars() {
    local v
    for v in PG_HOST VALKEY_HOST REDIS_HOST S3_ENDPOINT S3_REGION \
             AWS_REGION AZURE_STORAGE_ACCOUNT AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP \
             AZURE_NODE_RESOURCE_GROUP GCS_PROJECT_ID \
             LOKI_BUCKET LOKI_CONTAINER VELERO_BUCKET VELERO_CONTAINER CLUSTER_NAME \
             VAULT_KEY_VAULT_NAME VAULT_KEY_NAME VAULT_KMS_KEY_ID VAULT_KMS_REGION \
             VAULT_KMS_KEY_RING VAULT_KMS_CRYPTO_KEY ENTRA_TENANT_ID
    do
        [[ -n "${!v:-}" ]] || export "${v}=validation-placeholder"
    done
    export PG_PORT="${PG_PORT:-5432}" REDIS_PORT="${REDIS_PORT:-6379}"
}

check_helm_template() {
    local env="$1"

    command -v helm &>/dev/null || { log_warn "helm not found — skipping template checks"; return 0; }

    log_step "${env}: rendering Helm charts..."

    ENV="$env" setup_paths
    parse_config
    stub_infra_vars

    # Chart coordinates mirror the pins in deploy.sh. OCI charts are referenced by
    # URL; there is no repo to add.
    local -A charts=(
        [vault]="hashicorp/vault:0.34.1"
        [argocd]="argo/argo-cd:10.3.3"
        [external-dns]="external-dns/external-dns:1.21.1"
        [external-secrets]="external-secrets/external-secrets:2.9.0"
        [headlamp]="headlamp/headlamp:0.44.0"
        [homepage]="jameswynn/homepage:2.1.0"
        [velero]="vmware-tanzu/velero:12.1.0"
        [kyverno]="kyverno/kyverno:3.8.2"
        [reloader]="stakater/reloader:2.2.16"
        [woodpecker]="woodpecker/woodpecker:3.7.0"
        [forgejo]="oci://code.forgejo.org/forgejo-helm/forgejo:17.1.4"
        [gateway]="oci://docker.io/envoyproxy/gateway-helm:1.9.0"
        [monitoring]="prometheus-community/kube-prometheus-stack:88.3.0"
    )

    local component spec chart version args
    for component in "${!charts[@]}"; do
        spec="${charts[$component]}"
        # OCI references contain a colon in the scheme, so split on the last one.
        chart="${spec%:*}"
        version="${spec##*:}"

        # Skip components this environment does not configure.
        if [[ "$component" == "monitoring" ]]; then
            [[ -f "${BASE_DIR}/devops/monitoring/prometheus-stack-values.yaml" ]] || continue
        else
            [[ -f "${BASE_DIR}/devops/${component}/values.yaml" ]] || continue
        fi

        args="$(get_values_args "$component")"
        if ! helm template "$component" "$chart" --version "$version" $args >/dev/null 2>"${RENDER_DIR}/helm-${component}.err"; then
            fail "${env}: helm template failed for ${component} — $(head -3 "${RENDER_DIR}/helm-${component}.err" | tr '\n' ' ')"
        fi
    done
}

# =============================================================================
# 6. The devhub-app chart renders (local chart, no network needed)
# =============================================================================

# The chart every scaffolded app's k8s/values.yaml goes through. Rendered with
# the flags both ways so a broken conditional cannot hide, and with the same
# token substitution the portal performs on the template's values.yaml.
check_devhub_app_chart() {
    command -v helm &>/dev/null || { log_warn "helm not found — skipping devhub-app chart check"; return 0; }

    log_step "Rendering the devhub-app chart..."

    local chart="${K8S_DIR}/templates/devhub-app-chart"
    local values="${K8S_DIR}/templates/app-template/k8s/values.yaml"
    local render_dir
    render_dir="$(mktemp -d "${TMPDIR:-/tmp}/devhub-chart-validate.XXXXXX")"

    if ! helm lint "$chart" \
        --set app.name=demo --set app.host=demo.example.com \
        --set app.image.repository=git.example.com/devhub/demo \
        --set registry.host=git.example.com \
        >/dev/null 2>"${render_dir}/lint.err"; then
        fail "devhub-app chart: helm lint failed — $(head -3 "${render_dir}/lint.err" | tr '\n' ' ')"
    fi

    # Auth in both flip directions: protected app with public exceptions, and
    # public app with protected exceptions.
    local combo
    for combo in "true" "false"; do
        if ! helm template demo "$chart" \
            --set app.name=demo --set app.host=demo.example.com \
            --set app.image.repository=git.example.com/devhub/demo \
            --set registry.host=git.example.com \
            --set auth.enabled="$combo" --set 'auth.exceptPaths={/healthz}' \
            --set auth.issuer=https://keycloak.example.com/realms/devops \
            >/dev/null 2>"${render_dir}/auth.err"; then
            fail "devhub-app chart: helm template failed (auth.enabled=${combo} + exceptPaths) — $(head -3 "${render_dir}/auth.err" | tr '\n' ' ')"
        fi
    done

    # extraWorkloads: an off-the-shelf container per shape — routed, routed
    # with gateway auth, and in-cluster only.
    cat > "${render_dir}/workloads.yaml" <<'WLEOF'
app: {name: demo, host: demo.example.com, image: {repository: git.example.com/devhub/demo}}
registry: {host: git.example.com}
auth: {issuer: https://keycloak.example.com/realms/devops}
extraWorkloads:
  - {name: docs, image: ghcr.io/org/docs:1.0.0, port: 8080, host: docs-demo.example.com, runAsUser: 101, writableDirs: [/var/cache], probePath: /health}
  - {name: admin, image: quay.io/org/admin:2.0.0, port: 3000, host: admin-demo.example.com, auth: true}
  - {name: worker, image: docker.io/library/busybox:1.36, port: 9000}
WLEOF
    if ! helm template demo "$chart" -f "${render_dir}/workloads.yaml" \
        >/dev/null 2>"${render_dir}/workloads.err"; then
        fail "devhub-app chart: helm template failed (extraWorkloads) — $(head -3 "${render_dir}/workloads.err" | tr '\n' ' ')"
    fi

    local flags
    for flags in "false false" "true true"; do
        read -r pg redis <<<"$flags"
        # The portal's substitution, verbatim: the template's values.yaml with
        # the tokens replaced must be exactly what the chart can render.
        sed -e 's/APP_NAME/demo/g' -e 's/DOMAIN/example.com/g' \
            -e "s/POSTGRES_ENABLED/${pg}/g" -e "s/REDIS_ENABLED/${redis}/g" \
            "$values" > "${render_dir}/values.yaml"
        if ! helm template demo "$chart" -f "${render_dir}/values.yaml" \
            >/dev/null 2>"${render_dir}/template.err"; then
            fail "devhub-app chart: helm template failed (postgres=${pg} redis=${redis}) — $(head -3 "${render_dir}/template.err" | tr '\n' ' ')"
        fi
    done
    rm -rf "$render_dir"
}

# =============================================================================
# Main
# =============================================================================

echo "=============================================="
echo "Validating: ${ENVS[*]}"
echo "=============================================="

check_yaml_syntax
check_placeholders
check_appset_values
check_devhub_app_chart

for env in "${ENVS[@]}"; do
    log_step "Checking environment: ${env}"
    check_config_keys "$env"
    if $RUN_HELM; then
        ENV="$env"
        check_helm_template "$env"
    fi
done

echo ""
if [[ $FAILURES -eq 0 ]]; then
    log_info "All checks passed"
    exit 0
fi

log_error "${FAILURES} check(s) failed"
exit 1
