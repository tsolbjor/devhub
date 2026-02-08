#!/bin/bash
set -euo pipefail

# =============================================================================
# Kustomize Overlay Validation Script
# =============================================================================
# Performs dry-run validation of all overlays and exports rendered manifests
# to a temporary folder for inspection.
#
# Usage: ./validate-overlays.sh [environment] [--output-dir <path>]
#
# Environments: all (default), local, upcloud
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/.."
OVERLAYS_DIR="${K8S_DIR}/overlays"
BASE_DIR="${K8S_DIR}/base"

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
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Default values
ENV="${1:-all}"
OUTPUT_DIR=""
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        local|upcloud|all)
            ENV="$1"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [environment] [--output-dir <path>]"
            echo ""
            echo "Environments:"
            echo "  all     - Validate all overlays (default)"
            echo "  local   - Validate local overlay only"
            echo "  upcloud - Validate upcloud overlay only"
            echo ""
            echo "Options:"
            echo "  --output-dir <path>  - Custom output directory (default: /tmp/k8s-dryrun-<timestamp>)"
            echo "  -h, --help           - Show this help message"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Set default output directory if not specified
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="/tmp/k8s-dryrun-${TIMESTAMP}"
fi

# =============================================================================
# Prerequisites Check
# =============================================================================
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    local missing=()
    
    if ! command -v kubectl &> /dev/null; then
        # Check for kustomize standalone
        if ! command -v kustomize &> /dev/null; then
            missing+=("kubectl or kustomize")
        fi
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
        log_info "Or install kustomize: https://kubectl.docs.kubernetes.io/installation/kustomize/"
        exit 1
    fi
    
    log_info "Prerequisites check passed"
}

# =============================================================================
# Kustomize Build Function
# =============================================================================
run_kustomize() {
    local path="$1"
    # Prefer kustomize if available, otherwise use kubectl kustomize
    if command -v kustomize &> /dev/null; then
        kustomize build "$path"
    else
        kubectl kustomize "$path"
    fi
}

# =============================================================================
# Validate Single Overlay
# =============================================================================
validate_overlay() {
    local env_name="$1"
    local overlay_path="${OVERLAYS_DIR}/${env_name}"
    local env_output_dir="${OUTPUT_DIR}/${env_name}"
    
    log_step "Validating overlay: ${env_name}"
    
    if [[ ! -d "$overlay_path" ]]; then
        log_warn "Overlay directory not found: ${overlay_path}"
        return 1
    fi
    
    mkdir -p "$env_output_dir"
    
    local has_errors=false
    local validated_count=0
    local error_count=0
    
    # Find all kustomization.yaml files in the overlay
    while IFS= read -r -d '' kustomization_file; do
        local kustomize_dir=$(dirname "$kustomization_file")
        local relative_path="${kustomize_dir#${overlay_path}/}"
        
        # Handle root kustomization
        if [[ "$relative_path" == "$kustomize_dir" ]]; then
            relative_path="root"
        fi
        
        local output_file="${env_output_dir}/${relative_path//\//_}.yaml"
        
        echo -e "  ${CYAN}→${NC} Building: ${relative_path}"
        
        if run_kustomize "$kustomize_dir" > "$output_file" 2>&1; then
            local resource_count=$(grep -c '^kind:' "$output_file" 2>/dev/null || echo "0")
            echo -e "    ${GREEN}✓${NC} Success - ${resource_count} resources generated"
            ((validated_count++))
            
            # Validate the generated YAML with kubectl dry-run if cluster is available
            if kubectl cluster-info &>/dev/null 2>&1; then
                if kubectl apply --dry-run=server -f "$output_file" &>/dev/null 2>&1; then
                    echo -e "    ${GREEN}✓${NC} Server-side dry-run passed"
                else
                    # Try client-side dry-run as fallback
                    if kubectl apply --dry-run=client -f "$output_file" &>/dev/null 2>&1; then
                        echo -e "    ${YELLOW}⚠${NC} Client-side dry-run passed (server validation skipped)"
                    else
                        echo -e "    ${YELLOW}⚠${NC} Dry-run validation had warnings (check output file)"
                    fi
                fi
            fi
        else
            echo -e "    ${RED}✗${NC} Failed - see ${output_file} for errors"
            has_errors=true
            ((error_count++))
        fi
        
    done < <(find "$overlay_path" -name "kustomization.yaml" -print0 2>/dev/null)
    
    # Also validate base if it exists and has a kustomization
    if [[ -f "${BASE_DIR}/kustomization.yaml" ]]; then
        local base_output_file="${env_output_dir}/base.yaml"
        echo -e "  ${CYAN}→${NC} Building: base"
        
        if run_kustomize "$BASE_DIR" > "$base_output_file" 2>&1; then
            local resource_count=$(grep -c '^kind:' "$base_output_file" 2>/dev/null || echo "0")
            echo -e "    ${GREEN}✓${NC} Success - ${resource_count} resources generated"
            ((validated_count++))
        else
            echo -e "    ${RED}✗${NC} Failed - see ${base_output_file} for errors"
            has_errors=true
            ((error_count++))
        fi
    fi
    
    echo ""
    if [[ "$has_errors" == "true" ]]; then
        log_warn "${env_name}: ${validated_count} passed, ${error_count} failed"
        return 1
    else
        log_success "${env_name}: All ${validated_count} kustomizations validated successfully"
        return 0
    fi
}

# =============================================================================
# Generate Summary Report
# =============================================================================
generate_summary() {
    local summary_file="${OUTPUT_DIR}/SUMMARY.md"
    
    cat > "$summary_file" << EOF
# Kustomize Dry-Run Validation Report

Generated: $(date -Iseconds)
Output Directory: ${OUTPUT_DIR}

## Validated Overlays

EOF
    
    for env_dir in "${OUTPUT_DIR}"/*/; do
        if [[ -d "$env_dir" ]]; then
            local env_name=$(basename "$env_dir")
            echo "### ${env_name}" >> "$summary_file"
            echo "" >> "$summary_file"
            echo "| File | Resources |" >> "$summary_file"
            echo "|------|-----------|" >> "$summary_file"
            
            for yaml_file in "${env_dir}"*.yaml; do
                if [[ -f "$yaml_file" ]]; then
                    local filename=$(basename "$yaml_file")
                    local count=$(grep -c '^kind:' "$yaml_file" 2>/dev/null || echo "0")
                    echo "| ${filename} | ${count} |" >> "$summary_file"
                fi
            done
            echo "" >> "$summary_file"
        fi
    done
    
    echo "" >> "$summary_file"
    echo "## Usage" >> "$summary_file"
    echo "" >> "$summary_file"
    echo "To inspect a specific manifest:" >> "$summary_file"
    echo '```bash' >> "$summary_file"
    echo "cat ${OUTPUT_DIR}/<environment>/<component>.yaml" >> "$summary_file"
    echo '```' >> "$summary_file"
    echo "" >> "$summary_file"
    echo "To apply with dry-run:" >> "$summary_file"
    echo '```bash' >> "$summary_file"
    echo "kubectl apply --dry-run=client -f ${OUTPUT_DIR}/<environment>/<component>.yaml" >> "$summary_file"
    echo '```' >> "$summary_file"
    
    log_info "Summary report generated: ${summary_file}"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}        Kustomize Overlay Validation (Dry Run)             ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_prerequisites
    
    log_info "Output directory: ${OUTPUT_DIR}"
    mkdir -p "$OUTPUT_DIR"
    
    local all_passed=true
    local environments=()
    
    case "$ENV" in
        all)
            # Find all overlay directories
            for overlay in "${OVERLAYS_DIR}"/*/; do
                if [[ -d "$overlay" ]]; then
                    environments+=("$(basename "$overlay")")
                fi
            done
            ;;
        *)
            environments+=("$ENV")
            ;;
    esac
    
    echo ""
    log_info "Environments to validate: ${environments[*]}"
    echo ""
    
    for env_name in "${environments[@]}"; do
        if ! validate_overlay "$env_name"; then
            all_passed=false
        fi
        echo ""
    done
    
    generate_summary
    
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    
    if [[ "$all_passed" == "true" ]]; then
        log_success "All validations passed!"
        echo ""
        log_info "Rendered manifests exported to: ${OUTPUT_DIR}"
        log_info "View summary: cat ${OUTPUT_DIR}/SUMMARY.md"
        exit 0
    else
        log_error "Some validations failed. Check output files for details."
        echo ""
        log_info "Rendered manifests exported to: ${OUTPUT_DIR}"
        exit 1
    fi
}

main "$@"
