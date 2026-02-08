#!/bin/bash
set -euo pipefail

# =============================================================================
# Local CA and Certificate Setup Script
# =============================================================================
# This script creates a local Certificate Authority and generates certificates
# for local development with Kubernetes.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/../../certs"
CA_DIR="${CERTS_DIR}/ca"
DOMAIN_CERTS_DIR="${CERTS_DIR}/domains"

# Configuration
CA_NAME="Local Development CA"
CA_VALID_DAYS=3650  # 10 years
CERT_VALID_DAYS=825 # ~2 years

# Domains to generate certificates for
DOMAINS=(
    "local.dev"
    "*.local.dev"
    "app.local.dev"
    "api.local.dev"
    "auth.local.dev"
    "localhost"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check for required tools
check_requirements() {
    log_info "Checking requirements..."
    
    if ! command -v openssl &> /dev/null; then
        log_error "openssl is required but not installed."
        exit 1
    fi
    
    log_info "All requirements satisfied."
}

# Create directory structure
create_directories() {
    log_info "Creating certificate directories..."
    mkdir -p "${CA_DIR}"
    mkdir -p "${DOMAIN_CERTS_DIR}"
}

# Generate CA private key and certificate
generate_ca() {
    if [[ -f "${CA_DIR}/ca.key" && -f "${CA_DIR}/ca.crt" ]]; then
        log_warn "CA already exists. Skipping generation."
        log_warn "Delete ${CA_DIR} to regenerate."
        return 0
    fi
    
    log_info "Generating CA private key..."
    openssl genrsa -out "${CA_DIR}/ca.key" 4096
    
    log_info "Generating CA certificate..."
    openssl req -x509 -new -nodes \
        -key "${CA_DIR}/ca.key" \
        -sha256 \
        -days ${CA_VALID_DAYS} \
        -out "${CA_DIR}/ca.crt" \
        -subj "/CN=${CA_NAME}/O=Local Development/C=NO"
    
    # Also create a .pem copy for Windows compatibility
    cp "${CA_DIR}/ca.crt" "${CA_DIR}/ca.pem"
    
    log_info "CA certificate generated successfully."
    log_info "CA certificate location: ${CA_DIR}/ca.crt"
}

# Generate domain certificate
generate_domain_cert() {
    log_info "Generating domain certificate..."
    
    local CERT_NAME="local-dev"
    local KEY_FILE="${DOMAIN_CERTS_DIR}/${CERT_NAME}.key"
    local CSR_FILE="${DOMAIN_CERTS_DIR}/${CERT_NAME}.csr"
    local CERT_FILE="${DOMAIN_CERTS_DIR}/${CERT_NAME}.crt"
    local EXT_FILE="${DOMAIN_CERTS_DIR}/${CERT_NAME}.ext"
    
    # Generate private key
    log_info "Generating private key for domains..."
    openssl genrsa -out "${KEY_FILE}" 2048
    
    # Build SAN extension
    local SAN_ENTRIES=""
    local DNS_COUNT=1
    local IP_COUNT=1
    
    for domain in "${DOMAINS[@]}"; do
        if [[ "${domain}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            SAN_ENTRIES="${SAN_ENTRIES}IP.${IP_COUNT} = ${domain}\n"
            ((IP_COUNT++))
        else
            SAN_ENTRIES="${SAN_ENTRIES}DNS.${DNS_COUNT} = ${domain}\n"
            ((DNS_COUNT++))
        fi
    done
    
    # Add localhost IP
    SAN_ENTRIES="${SAN_ENTRIES}IP.${IP_COUNT} = 127.0.0.1\n"
    
    # Create extension file
    cat > "${EXT_FILE}" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
$(echo -e "${SAN_ENTRIES}")
EOF
    
    # Generate CSR
    log_info "Generating certificate signing request..."
    openssl req -new \
        -key "${KEY_FILE}" \
        -out "${CSR_FILE}" \
        -subj "/CN=local.dev/O=Local Development/C=NO"
    
    # Sign with CA
    log_info "Signing certificate with CA..."
    openssl x509 -req \
        -in "${CSR_FILE}" \
        -CA "${CA_DIR}/ca.crt" \
        -CAkey "${CA_DIR}/ca.key" \
        -CAcreateserial \
        -out "${CERT_FILE}" \
        -days ${CERT_VALID_DAYS} \
        -sha256 \
        -extfile "${EXT_FILE}"
    
    # Create combined PEM file
    cat "${CERT_FILE}" "${CA_DIR}/ca.crt" > "${DOMAIN_CERTS_DIR}/${CERT_NAME}-fullchain.crt"
    
    # Cleanup CSR and extension file
    rm -f "${CSR_FILE}" "${EXT_FILE}"
    
    log_info "Domain certificate generated successfully."
    log_info "Certificate: ${CERT_FILE}"
    log_info "Private Key: ${KEY_FILE}"
}

# Create Kubernetes TLS secret manifest
create_k8s_secret() {
    log_info "Creating Kubernetes TLS secret manifest..."
    
    local SECRET_FILE="${SCRIPT_DIR}/../../overlays/local/tls-secret.yaml"
    local CERT_B64=$(base64 -w 0 "${DOMAIN_CERTS_DIR}/local-dev.crt")
    local KEY_B64=$(base64 -w 0 "${DOMAIN_CERTS_DIR}/local-dev.key")
    
    mkdir -p "$(dirname "${SECRET_FILE}")"
    
    cat > "${SECRET_FILE}" << EOF
# Auto-generated - DO NOT EDIT
# Generated by setup-ca.sh
apiVersion: v1
kind: Secret
metadata:
  name: local-tls-secret
  namespace: tshub
type: kubernetes.io/tls
data:
  tls.crt: ${CERT_B64}
  tls.key: ${KEY_B64}
EOF
    
    log_info "Kubernetes TLS secret manifest created: ${SECRET_FILE}"
}

# Create CA ConfigMap for trust distribution
create_ca_configmap() {
    log_info "Creating CA ConfigMap manifest..."
    
    local CONFIGMAP_FILE="${SCRIPT_DIR}/../../overlays/local/ca-configmap.yaml"
    local CA_B64=$(base64 -w 0 "${CA_DIR}/ca.crt")
    
    cat > "${CONFIGMAP_FILE}" << EOF
# Auto-generated - DO NOT EDIT
# Generated by setup-ca.sh
# This ConfigMap contains the CA certificate for services to trust
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-ca-certificates
  namespace: tshub
data:
  ca.crt: |
$(cat "${CA_DIR}/ca.crt" | sed 's/^/    /')
---
apiVersion: v1
kind: Secret
metadata:
  name: local-ca-secret
  namespace: tshub
type: Opaque
data:
  ca.crt: ${CA_B64}
EOF
    
    log_info "CA ConfigMap manifest created: ${CONFIGMAP_FILE}"
}

# Print summary and next steps
print_summary() {
    echo ""
    echo "=============================================="
    echo "Certificate Setup Complete!"
    echo "=============================================="
    echo ""
    echo "Generated files:"
    echo "  CA Certificate:     ${CA_DIR}/ca.crt"
    echo "  CA Private Key:     ${CA_DIR}/ca.key"
    echo "  Domain Certificate: ${DOMAIN_CERTS_DIR}/local-dev.crt"
    echo "  Domain Private Key: ${DOMAIN_CERTS_DIR}/local-dev.key"
    echo ""
    echo "Domains covered:"
    for domain in "${DOMAINS[@]}"; do
        echo "  - ${domain}"
    done
    echo ""
    echo "Next steps:"
    echo "1. Install CA certificate on Windows (run as Administrator):"
    echo "   powershell -ExecutionPolicy Bypass -File scripts/windows/install-ca.ps1"
    echo ""
    echo "2. Update Windows hosts file:"
    echo "   powershell -ExecutionPolicy Bypass -File scripts/windows/setup-hosts.ps1"
    echo ""
    echo "3. Set up the local Kubernetes cluster:"
    echo "   ./setup-cluster.sh"
    echo ""
}

# Add .gitignore for certs directory
create_gitignore() {
    cat > "${CERTS_DIR}/.gitignore" << EOF
# Ignore all certificate files
*.key
*.crt
*.pem
*.csr
*.srl
EOF
    log_info "Created .gitignore for certificates directory"
}

# Main execution
main() {
    echo "=============================================="
    echo "Local CA and Certificate Setup"
    echo "=============================================="
    
    check_requirements
    create_directories
    create_gitignore
    generate_ca
    generate_domain_cert
    create_k8s_secret
    create_ca_configmap
    print_summary
}

main "$@"
