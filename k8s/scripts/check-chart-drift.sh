#!/usr/bin/env bash
# Chart pins versus reality.
#
# Every chart is pinned in k8s/scripts/deploy.sh (and deploy-workload.sh). Half
# of them are reconciled from git by ArgoCD, so a merged bump applies itself. The
# other half — the bootstrap components that install the GitOps machinery, and so
# cannot be installed by it — are applied only when somebody runs deploy.sh. That
# asymmetry is invisible: the repository says 1.9.0, the cluster runs 1.8.2, and
# nothing anywhere says so.
#
# Two modes, because there are two moments when it matters:
#
#   (no args)              What is pinned, what is installed, and where they
#                          differ. Needs a cluster. Called by
#                          `deploy.sh <env> all status`.
#
#   --changed-since <ref>  Which bootstrap pins this commit range changed, and
#                          the exact command each one now needs. Needs git only,
#                          no cluster — this is the CI step that runs on the pull
#                          request that bumps the pin, which is the one moment
#                          the operator is looking.
#
# Exit status is 0 in both modes unless --strict is given: a pending restart is
# information, not a broken build. --strict makes it a failure, for anyone who
# wants the merge blocked until the component is rolled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

MODE="installed"
SINCE=""
STRICT=false
ENV_ARG=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --changed-since) MODE="changed"; SINCE="${2:-}"; shift 2 ;;
        --strict)        STRICT=true; shift ;;
        --env)           ENV_ARG+=(--env "${2:-}"); shift 2 ;;
        -h|--help)
            sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ─── The pins, and which half of the platform each one belongs to ─────
#
# Membership is derived, not listed: a chart named in platform-appset.yaml is
# reconciled by ArgoCD, anything else is installed by deploy.sh. A new component
# therefore classifies itself, and a component that moves from one half to the
# other (bootstrap → GitOps is the usual direction) needs no edit here.
APPSET="${SCRIPT_DIR}/../argocd/platform-appset.yaml"

declare -A PIN_VERSION=()   # chart name → pinned version
declare -A PIN_VAR=()       # chart name → the CHART_* constant
declare -A IN_APPSET=()     # chart name → yes, if ArgoCD reconciles it

load_pins() {
    local script line var version dep
    for script in "${SCRIPT_DIR}/deploy.sh" "${SCRIPT_DIR}/deploy-workload.sh"; do
        [[ -f "$script" ]] || continue
        while IFS= read -r line; do
            var="${line%%=*}"
            version="${line#*=\"}"
            version="${version%%\"*}"
            dep=""
            [[ "$line" =~ depName=([^[:space:]]+) ]] && dep="${BASH_REMATCH[1]}"
            [[ -n "$dep" && -n "$version" ]] || continue
            PIN_VERSION[$dep]="$version"
            PIN_VAR[$dep]="$var"
        done < <(grep -E '^CHART_[A-Z_]+="[^"]+"' "$script")
    done

    local chart
    if [[ -f "$APPSET" ]]; then
        while read -r chart; do
            [[ -n "$chart" ]] && IN_APPSET[$chart]="yes"
        done < <(grep -oE '^[[:space:]]*chart: [^[:space:]]+' "$APPSET" | awk '{print $2}')
    fi
}

# The component name deploy.sh answers to, which is what the operator has to
# type. It matches the chart name for most, so only the exceptions are listed.
component_for() {
    case "$1" in
        argo-cd)              echo "argocd" ;;
        gateway-helm)         echo "gateway" ;;
        kube-prometheus-stack) echo "monitoring" ;;
        *)                    echo "$1" ;;
    esac
}

# ─── Mode: what is installed ─────────────────────────────────────────
report_installed() {
    command -v helm &>/dev/null || { log_error "helm is required"; exit 1; }

    local releases
    releases="$(helm list -A -o json 2>/dev/null || echo '[]')"

    echo "=== Chart pins (pinned → installed) ==="
    printf '  %-24s %-12s %-12s %s\n' CHART PINNED INSTALLED ""

    local chart pinned found installed owner drift=0
    for chart in $(printf '%s\n' "${!PIN_VERSION[@]}" | sort); do
        pinned="${PIN_VERSION[$chart]}"
        # helm reports the chart as "<name>-<version>"; the longest-prefix match
        # is the release for this pin.
        found="$(printf '%s' "$releases" | jq -r --arg c "$chart" \
            '.[] | select(.chart | startswith($c + "-")) | .chart' 2>/dev/null | head -1)"
        installed="${found#"${chart}-"}"
        owner="ArgoCD"
        [[ -z "${IN_APPSET[$chart]:-}" ]] && owner="deploy.sh"

        if [[ -z "$found" ]]; then
            printf '  %-24s %-12s %-12s %s\n' "$chart" "$pinned" "-" "not installed"
        elif [[ "$installed" == "$pinned" ]]; then
            printf '  %-24s %-12s %-12s %s\n' "$chart" "$pinned" "$installed" "ok"
        else
            drift=$((drift + 1))
            printf '  %-24s %-12s %-12s %s\n' "$chart" "$pinned" "$installed" \
                "DRIFT — owner: ${owner}"
        fi
    done

    if (( drift > 0 )); then
        echo ""
        log_warn "${drift} chart(s) differ from their pin."
        log_warn "Where the owner is ArgoCD, the Application has not synced yet — check argocd."
        log_warn "Where it is deploy.sh, nothing will apply it until you do:"
        log_warn "  ./deploy.sh --env <env> <component>"
        $STRICT && return 1
    fi
    return 0
}

# ─── Mode: what this commit range changed ────────────────────────────
report_changed() {
    [[ -n "$SINCE" ]] || { log_error "--changed-since needs a git ref"; exit 1; }
    command -v git &>/dev/null || { log_error "git is required"; exit 1; }

    # A shallow CI clone may not contain the ref being compared against. Say so
    # rather than reporting "nothing changed", which is the same output as a
    # clean diff and would quietly stop warning about anything at all.
    if ! git rev-parse --verify --quiet "$SINCE" >/dev/null; then
        log_warn "Cannot compare against '${SINCE}' — it is not in this clone"
        log_warn "(a shallow CI checkout does this; fetch more history to enable the check)"
        return 0
    fi

    local diff
    # Only the deploy scripts, and only added lines: a removed pin is a component
    # going away, which is not a pending restart.
    diff="$(git diff "${SINCE}" -- "k8s/scripts/deploy.sh" "k8s/scripts/deploy-workload.sh" 2>/dev/null \
            | grep -E '^\+CHART_[A-Z_]+="' || true)"

    if [[ -z "$diff" ]]; then
        log_info "No chart pins changed in ${SINCE}..HEAD"
        return 0
    fi

    local line var version dep chart pending=()
    while IFS= read -r line; do
        line="${line#+}"
        var="${line%%=*}"
        version="${line#*=\"}"
        version="${version%%\"*}"
        dep=""
        [[ "$line" =~ depName=([^[:space:]]+) ]] && dep="${BASH_REMATCH[1]}"
        [[ -n "$dep" ]] || continue
        if [[ -n "${IN_APPSET[$dep]:-}" ]]; then
            log_info "${dep} → ${version}: reconciled by ArgoCD, no action needed"
        else
            pending+=("${dep} ${version}")
        fi
    done <<< "$diff"

    [[ ${#pending[@]} -eq 0 ]] && return 0

    echo ""
    log_warn "These components install the GitOps machinery, so ArgoCD does not"
    log_warn "manage them. Their pins moved in this change and the cluster will"
    log_warn "keep running the old version until somebody runs:"
    echo ""
    local entry
    for entry in "${pending[@]}"; do
        chart="${entry%% *}"
        echo "  ./deploy.sh --env <env> $(component_for "$chart")   # ${entry}"
    done
    echo ""
    log_warn "Check the result with: ./deploy.sh --env <env> all status"
    $STRICT && return 1
    return 0
}

load_pins

if [[ "$MODE" == "changed" ]]; then
    report_changed
else
    # Cluster mode only: the diff mode is deliberately usable in CI, where there
    # is no kubeconfig and no environment to match.
    if [[ ${#ENV_ARG[@]} -gt 0 ]]; then
        parse_env_arg "${ENV_ARG[@]}"
        setup_paths
        use_env_kubeconfig
        require_cluster_match
    fi
    report_installed
fi
