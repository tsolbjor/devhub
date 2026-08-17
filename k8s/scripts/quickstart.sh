#!/bin/bash
set -uo pipefail

# =============================================================================
# Quickstart — guided, resumable path from a fresh clone to a running platform
# =============================================================================
# Detects what is already done, shows a checklist, and runs the next pending step.
# Safe to re-run at any point: every step is detected, and nothing is repeated
# unless you ask for it.
#
# Usage:
#   ./quickstart.sh                                    pick an environment, then menu
#   ./quickstart.sh --env aws-dev                      straight to that environment
#   ./quickstart.sh --env aws-dev --status             checklist only, no prompts
#   ./quickstart.sh --env aws-dev --run-remaining-steps
#                                          run every pending step, still asking before
#                                          anything that costs money or replaces resources
#   ./quickstart.sh --env aws-dev --auto               same, but answer yes to everything
#
# Each step delegates to the script that owns it, so a step run here and the same
# step run by hand are the same thing.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="${SCRIPT_DIR}/../.."
DEVHUB="${REPO_ROOT}/devhub"

ENV=""
STATUS_ONLY=false
AUTO=false
RUN_REMAINING=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)     ENV="${2:-}"; shift 2 ;;
        --status)  STATUS_ONLY=true; shift ;;
        # Non-interactive equivalent of the menu's "Run every remaining step".
        # Confirmations for costly or destructive steps are still asked.
        --run-remaining-steps|--runremainingsteps|--run-remaining|-r)
            RUN_REMAINING=true; shift ;;
        # As above, plus assume yes for every confirmation (unattended).
        --auto|--yes-to-all|-y)
            AUTO=true; RUN_REMAINING=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: ./devhub quickstart [--env <environment>] [options]
       (equivalently: k8s/scripts/quickstart.sh ...)

  --env <environment>        environment to work on (prompted if omitted)
  --status                   print the checklist and exit
  --run-remaining-steps, -r  run every pending step; still prompts before
                             anything that costs money or replaces resources
  --auto, -y                 as above, but answer yes to every confirmation
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

BOLD='\033[1m'
DIM='\033[2m'

# ─── Small UI helpers ─────────────────────────────────────────────────

hr() { echo -e "${CYAN}────────────────────────────────────────────────────────────────────${NC}"; }

banner() {
    echo ""
    hr
    echo -e "${CYAN}${BOLD}  $1${NC}"
    hr
}

# choose <prompt> <var> <label>... — numbered menu, first entry is the default.
choose() {
    local prompt="$1" var="$2"; shift 2
    local -a labels=("$@")
    local i answer

    echo ""
    echo -e "${BOLD}${prompt}${NC}"
    for i in "${!labels[@]}"; do
        printf '  %d) %s\n' $((i + 1)) "${labels[$i]}"
    done
    read -r -p "  Choice [1]: " answer
    answer="${answer:-1}"

    if ! [[ "$answer" =~ ^[0-9]+$ ]] || (( answer < 1 || answer > ${#labels[@]} )); then
        log_error "Invalid choice"
        return 1
    fi
    printf -v "$var" '%s' "$answer"
}

confirm() {
    local answer
    $AUTO && return 0

    # No terminal to ask on: refuse rather than guess. Callers treat a "no" as
    # "stop here", which is the safe outcome for apply-type steps.
    if [[ ! -t 0 ]]; then
        log_warn "Confirmation needed but stdin is not a terminal — use --auto to accept automatically"
        return 1
    fi

    read -r -p "  $1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy] ]]
}

# ─── Environment selection ────────────────────────────────────────────

select_env() {
    local pick
    choose "Which environment?" pick \
        "local            — Rancher Desktop / WSL2, no cloud account needed" \
        "aws-dev          — EKS + RDS + ElastiCache + S3" \
        "azure-dev        — AKS + PostgreSQL Flexible Server + Redis + Blob" \
        "gcp-dev          — GKE + Cloud SQL + Memorystore + GCS" \
        "upcloud-dev      — UCS + Managed PG + Valkey + Object Storage" \
        "something else   — type the environment name" || exit 1

    case "$pick" in
        1) ENV="local" ;;
        2) ENV="aws-dev" ;;
        3) ENV="azure-dev" ;;
        4) ENV="gcp-dev" ;;
        5) ENV="upcloud-dev" ;;
        6)
            echo ""
            echo "  Platform: ${PLATFORM_ENVS}"
            echo "  Workload: ${WORKLOAD_ENVS}"
            read -r -p "  Environment: " ENV
            ;;
    esac

    if [[ " ${PLATFORM_ENVS} ${WORKLOAD_ENVS} " != *" ${ENV} "* ]]; then
        log_error "Unknown environment: ${ENV}"
        exit 1
    fi
}

if [[ -z "$ENV" ]]; then
    banner "devhub quickstart"
    echo "  Guided setup. Re-runnable: it detects what is done and continues from there."
    select_env
fi

CLOUD="$([[ "$ENV" == "local" ]] && echo local || echo "${ENV%%-*}")"
case "$ENV" in
    *-workload) TIER="workload" ;;
    *-prod)     TIER="prod" ;;
    *-dev)      TIER="dev" ;;
    local)      TIER="local" ;;
esac

TOFU_DIR=""
[[ "$CLOUD" != "local" ]] && TOFU_DIR="${REPO_ROOT}/tofu/${CLOUD}/${TIER}"
CONFIG_FILE="${REPO_ROOT}/k8s/overlays/${ENV}/config.yaml"
ENV_DIR="${SCRIPT_DIR}/${ENV}"
KUBECONFIG_FILE="${ENV_DIR}/kubeconfig"

# ─── Detection ────────────────────────────────────────────────────────
#
# Each check is cheap and read-only. kubectl calls are bounded so an unreachable
# cluster costs a second, not a hang.

kc() {
    if [[ -f "$KUBECONFIG_FILE" ]]; then
        KUBECONFIG="$KUBECONFIG_FILE" kubectl --request-timeout=8s "$@" 2>/dev/null
        return
    fi

    # A cloud environment with no kubeconfig of its own has no cluster to probe.
    # Falling back to the ambient context would report the state of whatever
    # cluster happens to be loaded — which made aws-dev's checklist show ✓ marks
    # that actually described the local Rancher Desktop cluster.
    [[ "$ENV" == "local" ]] || return 1

    kubectl --request-timeout=8s "$@" 2>/dev/null
}

det_tools()      { command -v kubectl &>/dev/null && command -v helm &>/dev/null \
                   && command -v jq &>/dev/null && command -v envsubst &>/dev/null; }
det_prereq()     { [[ -f "${ENV_DIR}/preflight.ok" ]]; }

# The DNS zone must exist in the cloud before `tofu apply`: the AWS and Azure
# modules look it up with a data source, so the plan fails without it. GCP and
# UpCloud only need it before certificates can be issued.
det_dnszone() {
    [[ -n "$TOFU_DIR" ]] || return 0
    local domain
    domain="$(yaml_get "$CONFIG_FILE" domain)"
    [[ -n "$domain" && "$domain" != *example.com ]] || return 1
    case "$CLOUD" in
        aws)   [[ -n "$(aws route53 list-hosted-zones-by-name --dns-name "${domain}." \
                        --query "HostedZones[?Name=='${domain}.'].Id" --output text 2>/dev/null | grep -v '^None$')" ]] ;;
        azure) [[ -n "$(az network dns zone list --query "[?name=='${domain}'].name" -o tsv 2>/dev/null)" ]] ;;
        gcp)   [[ -n "$(gcloud dns managed-zones list --filter="dnsName=${domain}." --format='value(name)' 2>/dev/null)" ]] ;;
        # UpCloud uses Cloudflare; the token secret is the closest observable proxy.
        upcloud) kc get secret external-dns-cloudflare -n external-dns >/dev/null ;;
    esac
}

det_config()     { [[ -z "$TOFU_DIR" ]] || { [[ -f "${TOFU_DIR}/backend.hcl" ]] && [[ -f "${TOFU_DIR}/terraform.tfvars" ]]; }; }
det_domain()     { local d; d="$(yaml_get "$CONFIG_FILE" domain)"; [[ -n "$d" && "$d" != *example.com ]]; }
det_init()       { [[ -z "$TOFU_DIR" ]] || [[ -f "${TOFU_DIR}/.terraform/terraform.tfstate" ]] \
                   || (cd "$TOFU_DIR" && tofu output -json &>/dev/null); }
det_applied()    { [[ -z "$TOFU_DIR" ]] || (cd "$TOFU_DIR" && [[ -n "$(tofu output -raw cluster_name 2>/dev/null)" ]]); }
det_synced()     { [[ -z "$TOFU_DIR" ]] || [[ -f "${ENV_DIR}/tofu-outputs.env" ]]; }
det_reachable()  { kc get --raw /readyz >/dev/null; }
det_dbusers()    { [[ "$CLOUD" == "local" || "$CLOUD" == "upcloud" ]] || kc get secret keycloak-db-secret -n keycloak >/dev/null; }
det_certs()      { [[ "$ENV" != "local" ]] || [[ -f "${REPO_ROOT}/k8s/certs/domains/local-dev.crt" ]]; }
# "Deployed" has to mean the components later steps depend on are present, not just
# that something got installed. Checking only argocd-server let a half-finished
# deploy look complete, and the Keycloak step then failed on a missing pod.
det_deployed() {
    kc get deploy argocd-server -n argocd >/dev/null || return 1
    kc get statefulset -n keycloak -o name 2>/dev/null | grep -q . || return 1
    kc get statefulset -n vault -o name 2>/dev/null | grep -q . || return 1
    kc get deploy -n forgejo -o name 2>/dev/null | grep -q . || return 1
    kc get deploy -n monitoring -o name 2>/dev/null | grep -q grafana
}

# The Gateway is what makes anything reachable; check the controller and that the
# Gateway object reports an address.
det_gateway() {
    kc get deploy envoy-gateway -n envoy-gateway-system >/dev/null || return 1
    [[ -n "$(kc get gateway devhub -n gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)" ]]
}

det_policy() {
    kc get deploy -n kyverno -o name 2>/dev/null | grep -q admission || return 1
    kc get clusterpolicy devhub-namespace-defaults >/dev/null
}
det_wl_deployed(){ kc get deploy -n external-secrets >/dev/null && kc get ds -n monitoring >/dev/null; }
# NOTE on jq: `.sealed // true` is wrong here — jq's `//` also substitutes when the
# left side is `false`, so an unsealed Vault would read as sealed. Compare the raw
# values; an absent field renders as "null" and fails both tests, which is the safe
# direction.
det_vault() {
    # vault-0 is a StatefulSet ordinal, so the name is stable across installs.
    local out
    out="$(kc exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
             vault status -format=json 2>/dev/null)"
    [[ -n "$out" ]] || return 1
    [[ "$(echo "$out" | jq -r '.initialized')" == "true" ]] || return 1
    [[ "$(echo "$out" | jq -r '.sealed')" == "false" ]]
}
# The generated client-secret file is the marker, but it survives a cluster rebuild,
# so Keycloak itself must also be running. Matched by label rather than pod name,
# which depends on the chart's release name.
det_keycloak() {
    [[ -f "${ENV_DIR}/oidc-secrets.env" ]] || return 1
    kc get pod -n keycloak -l app=keycloak -o name 2>/dev/null | grep -q .
}
det_secrets()    { kc get externalsecret forgejo-db-secret -n forgejo >/dev/null; }
det_appofapps()  { kc get application devhub-apps -n argocd >/dev/null; }
det_gitops()     { kc get applicationset platform-components -n argocd >/dev/null; }
det_registered() { kc get secret loki-ingest-credentials -n monitoring >/dev/null; }

# ─── Step table ───────────────────────────────────────────────────────
#
# name | label | detector | action
# Actions are devhub commands so the guided path and the manual path stay identical.

STEP_KEYS=()
STEP_LABEL=()
STEP_DETECT=()
STEP_ACTION=()

step() {
    STEP_KEYS+=("$1"); STEP_LABEL+=("$2"); STEP_DETECT+=("$3"); STEP_ACTION+=("$4")
}

if [[ "$ENV" == "local" ]]; then
    step tools     "Required tooling installed"              det_tools     "doctor"
    step prereq    "Prerequisites confirmed"                 det_prereq    "preflight --env ${ENV}"
    step certs     "Local CA and TLS certificates"           det_certs     "ca --env ${ENV}"
    step reachable "Cluster reachable"                       det_reachable ""
    step deployed  "Platform deployed"                       det_deployed  "deploy --env ${ENV}"
    step gateway   "Gateway serving traffic"                 det_gateway   "deploy --env ${ENV} gateway"
    step policy    "Kyverno policies active"                 det_policy    "deploy --env ${ENV} kyverno"
    step vault     "Vault initialised and unsealed"          det_vault     "vault --env ${ENV}"
    step keycloak  "Keycloak realm and OIDC clients"         det_keycloak  "keycloak --env ${ENV}"
    step secrets   "Credentials moved into Vault"            det_secrets   "secrets --env ${ENV}"
    step appofapps "ArgoCD app-of-apps"                      det_appofapps "deploy --env ${ENV} bootstrap"
    step gitops    "Platform handed to ArgoCD"               det_gitops    "gitops --env ${ENV}"
elif [[ "$TIER" == "workload" ]]; then
    step tools     "Required tooling installed"              det_tools     "doctor"
    step prereq    "Prerequisites confirmed"                 det_prereq    "preflight --env ${ENV}"
    step config    "backend.hcl + terraform.tfvars"          det_config    "setup --env ${ENV}"
    step domain    "Domain set in config.yaml"               det_domain    "setup --env ${ENV} --force"
    step dnszone   "DNS zone exists and is delegated"        det_dnszone   "preflight --env ${ENV} --dns"
    step init      "OpenTofu initialised"                    det_init      "init --env ${ENV}"
    step applied   "Infrastructure provisioned"              det_applied   "apply --env ${ENV}"
    step synced    "Outputs and kubeconfig synced"           det_synced    "sync --env ${ENV}"
    step reachable "Cluster reachable"                       det_reachable ""
    step deployed  "Workload components deployed"            det_wl_deployed "deploy --env ${ENV}"
    step registered "Registered with the platform"           det_registered "register --env ${ENV}"
else
    step tools     "Required tooling installed"              det_tools     "doctor"
    step prereq    "Prerequisites confirmed"                 det_prereq    "preflight --env ${ENV}"
    step config    "backend.hcl + terraform.tfvars"          det_config    "setup --env ${ENV}"
    step domain    "Domain set in config.yaml"               det_domain    "setup --env ${ENV} --force"
    step dnszone   "DNS zone exists and is delegated"        det_dnszone   "preflight --env ${ENV} --dns"
    step init      "OpenTofu initialised"                    det_init      "init --env ${ENV}"
    step applied   "Infrastructure provisioned"              det_applied   "apply --env ${ENV}"
    step synced    "Outputs and kubeconfig synced"           det_synced    "sync --env ${ENV}"
    step reachable "Cluster reachable"                       det_reachable ""
    step dbusers   "Managed PostgreSQL users"                det_dbusers   "db-users --env ${ENV}"
    step deployed  "Platform deployed"                       det_deployed  "deploy --env ${ENV}"
    step gateway   "Gateway serving traffic"                 det_gateway   "deploy --env ${ENV} gateway"
    step policy    "Kyverno policies active"                 det_policy    "deploy --env ${ENV} kyverno"
    step vault     "Vault initialised and unsealed"          det_vault     "vault --env ${ENV}"
    step keycloak  "Keycloak realm and OIDC clients"         det_keycloak  "keycloak --env ${ENV}"
    step secrets   "Credentials moved into Vault"            det_secrets   "secrets --env ${ENV}"
    step appofapps "ArgoCD app-of-apps"                      det_appofapps "deploy --env ${ENV} bootstrap"
    step gitops    "Platform handed to ArgoCD"               det_gitops    "gitops --env ${ENV}"
fi

# Populated by refresh_state(): "done" / "todo" per step, and the first pending index.
STEP_STATE=()
NEXT_INDEX=-1

refresh_state() {
    STEP_STATE=()
    NEXT_INDEX=-1
    local i
    for i in "${!STEP_KEYS[@]}"; do
        if "${STEP_DETECT[$i]}"; then
            STEP_STATE+=("done")
        else
            STEP_STATE+=("todo")
            [[ $NEXT_INDEX -lt 0 ]] && NEXT_INDEX=$i
        fi
    done
}

print_checklist() {
    local i mark colour
    echo ""
    echo -e "${BOLD}  ${ENV}${NC}  (${CLOUD}${TOFU_DIR:+ / ${TOFU_DIR#"${REPO_ROOT}/"}})"
    echo ""
    for i in "${!STEP_KEYS[@]}"; do
        if [[ "${STEP_STATE[$i]}" == "done" ]]; then
            mark="✓"; colour="$GREEN"
        elif [[ $i -eq $NEXT_INDEX ]]; then
            mark="→"; colour="$YELLOW"
        else
            mark="·"; colour="$DIM"
        fi
        printf '  %b%s %s%b\n' "$colour" "$mark" "${STEP_LABEL[$i]}" "$NC"
    done
    echo ""

    if [[ $NEXT_INDEX -lt 0 ]]; then
        log_info "Everything is done for ${ENV}"
        local d; d="$(yaml_get "$CONFIG_FILE" domain)"
        [[ -n "$d" ]] && echo "         https://argocd.${d}  https://grafana.${d}  https://git.${d}  https://ci.${d}"
        # The one thing no script can do for you: the GitOps repo has to exist.
        local repo; repo="$(yaml_get "$CONFIG_FILE" gitops.repoUrl)"
        if [[ -n "$repo" ]] && kc get application -n argocd -o jsonpath='{.items[*].status.sync.status}' 2>/dev/null | grep -q Unknown; then
            echo ""
            log_warn "ArgoCD cannot read ${repo} yet — its Applications show Sync=Unknown."
            log_warn "Create the repository in Forgejo, then push this checkout to it:"
            log_warn "  git remote add forgejo ${repo} && git push forgejo main"
        fi
    else
        local action="${STEP_ACTION[$NEXT_INDEX]}"
        if [[ -n "$action" ]]; then
            echo -e "  ${BOLD}Next:${NC} ./devhub ${action}"
        else
            # A step with no action is a precondition someone else has to satisfy.
            case "${STEP_KEYS[$NEXT_INDEX]}" in
                reachable)
                    echo -e "  ${BOLD}Next:${NC} make the cluster reachable"
                    if [[ "$ENV" == "local" ]]; then
                        echo "         start Rancher Desktop (or your local Kubernetes)"
                    else
                        echo "         check the API allow-list: ./devhub setup --env ${ENV} --force"
                        echo "         or refresh credentials:   ./devhub sync --env ${ENV}"
                    fi
                    ;;
            esac
        fi
    fi
}

run_step() {
    local i="$1"
    local key="${STEP_KEYS[$i]}" action="${STEP_ACTION[$i]}"

    if [[ -z "$action" ]]; then
        log_warn "'${STEP_LABEL[$i]}' is a precondition this script cannot perform for you."
        return 1
    fi

    banner "${STEP_LABEL[$i]}"

    # `apply` costs money and can be destructive: always show the plan first.
    if [[ "$key" == "applied" ]]; then
        log_info "Reviewing the plan before applying"
        # shellcheck disable=SC2086
        "$DEVHUB" plan --env "$ENV" || return 1
        echo ""
        log_warn "Review the plan above. Creating cloud resources costs money;"
        log_warn "changes to private-cluster settings can replace an existing cluster."
        confirm "Apply this plan?" || { log_warn "Not applied"; return 1; }
    fi

    # shellcheck disable=SC2086
    "$DEVHUB" $action
}

run_all_pending() {
    local guard=0
    while :; do
        refresh_state
        [[ $NEXT_INDEX -lt 0 ]] && { log_info "All steps complete"; return 0; }

        guard=$((guard + 1))
        if [[ $guard -gt ${#STEP_KEYS[@]} ]]; then
            log_error "Stopped: a step reported success but its check still fails"
            log_error "  step: ${STEP_LABEL[$NEXT_INDEX]}"
            return 1
        fi

        local before="${STEP_KEYS[$NEXT_INDEX]}"
        run_step "$NEXT_INDEX" || return 1

        refresh_state
        if [[ $NEXT_INDEX -ge 0 && "${STEP_KEYS[$NEXT_INDEX]}" == "$before" ]]; then
            log_warn "'${STEP_LABEL[$NEXT_INDEX]}' is still not complete — stopping here"
            return 1
        fi
    done
}

# ─── Changing settings after the fact ─────────────────────────────────

change_settings() {
    banner "Change settings — ${ENV}"

    cat <<EOF
  Safe to change any time
    ACME email               new certificates use it; existing ones are unaffected
    API allow-list           tofu apply updates the control plane in place
    Entra admin groups       Azure only; tofu apply updates cluster RBAC

  Changeable, with follow-up work
    Domain                   gateway listeners, certificates, Keycloak redirect URIs
                             and Forgejo's root URL all derive from it, so the
                             platform must be redeployed afterwards

  Not changeable here
    State bucket / region    moving state needs 'tofu init -migrate-state'
    GCP project, cloud region  would replace the whole environment

EOF

    local pick
    choose "What do you want to change?" pick \
        "Safe settings (email, API allow-list, admin groups)" \
        "Domain (and then redeploy)" \
        "Back" || return 0

    case "$pick" in
        1)
            "$DEVHUB" setup --env "$ENV" --force || return 1
            echo ""
            if [[ -n "$TOFU_DIR" ]]; then
                log_info "API allow-list and admin groups take effect on the next apply."
                confirm "Run plan + apply now?" && run_apply_now
            fi
            ;;
        2)
            log_warn "Changing the domain means re-issuing certificates and reconfiguring SSO."
            confirm "Continue?" || return 0
            "$DEVHUB" setup --env "$ENV" --force || return 1
            echo ""
            log_info "Follow-up, in order:"
            echo "    ./devhub deploy   --env ${ENV}      # ingress hosts + service URLs"
            echo "    ./devhub keycloak --env ${ENV}      # redirect URIs for the new domain"
            echo "    update DNS so *.<new domain> points at the ingress LoadBalancer"
            confirm "Run the redeploy now?" && { "$DEVHUB" deploy --env "$ENV" && "$DEVHUB" keycloak --env "$ENV"; }
            ;;
        3) return 0 ;;
    esac
}

run_apply_now() {
    "$DEVHUB" plan --env "$ENV" || return 1
    confirm "Apply?" && "$DEVHUB" apply --env "$ENV"
}

# ─── Main ─────────────────────────────────────────────────────────────

refresh_state

if $STATUS_ONLY; then
    print_checklist
    exit 0
fi

if $RUN_REMAINING; then
    print_checklist
    if ! $AUTO && [[ ! -t 0 ]]; then
        log_warn "--run-remaining-steps still asks before applying infrastructure changes,"
        log_warn "and there is no terminal to ask on. Use --auto for a fully unattended run."
    fi
    run_all_pending
    exit $?
fi

while :; do
    refresh_state
    print_checklist

    if [[ $NEXT_INDEX -lt 0 ]]; then
        local_pick=""
        choose "What now?" local_pick \
            "Show status again" \
            "Change settings" \
            "Quit" || exit 0
        case "$local_pick" in
            1) continue ;;
            2) change_settings ;;
            3) exit 0 ;;
        esac
        continue
    fi

    pick=""
    if [[ -n "${STEP_ACTION[$NEXT_INDEX]}" ]]; then
        choose "What now?" pick \
            "Run the next step  (${STEP_LABEL[$NEXT_INDEX]})" \
            "Run every remaining step" \
            "Change settings" \
            "Quit" || exit 0
    else
        choose "What now?" pick \
            "Re-check (waiting on: ${STEP_LABEL[$NEXT_INDEX]})" \
            "Run every remaining step" \
            "Change settings" \
            "Quit" || exit 0
    fi

    case "$pick" in
        1)
            if [[ -n "${STEP_ACTION[$NEXT_INDEX]}" ]]; then
                run_step "$NEXT_INDEX" || log_warn "Step did not complete — the checklist below shows where you are"
            fi
            ;;
        2) run_all_pending || log_warn "Stopped before the end — re-run quickstart to continue" ;;
        3) change_settings ;;
        4) exit 0 ;;
    esac
done
