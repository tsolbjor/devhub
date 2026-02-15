#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "========================================="
echo "  Kubernetes Cluster Setup Script"
echo "========================================="
echo ""

# Check prerequisites
echo "=== Checking Prerequisites ==="
command -v tofu >/dev/null 2>&1 || { echo "Error: tofu is not installed. Please install OpenTofu first."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl is not installed."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "Error: helm is not installed."; exit 1; }
echo "✓ All prerequisites are installed"
echo ""

# Deploy infrastructure
echo "=== Step 1: Deploying Infrastructure with OpenTofu ==="
cd "$PROJECT_ROOT/tofu"

if [ ! -f "terraform.tfvars" ]; then
    echo "Warning: terraform.tfvars not found. Using default values."
    echo "Consider copying terraform.tfvars.example to terraform.tfvars and customizing it."
    read -p "Continue with defaults? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "Initializing OpenTofu..."
tofu init

echo "Planning infrastructure..."
tofu plan -out=tfplan

read -p "Apply this plan? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Applying infrastructure..."
    tofu apply tfplan
    
    echo "Saving kubeconfig..."
    tofu output -raw kubeconfig > "$PROJECT_ROOT/kubeconfig"
    chmod 600 "$PROJECT_ROOT/kubeconfig"
    export KUBECONFIG="$PROJECT_ROOT/kubeconfig"
    
    echo "✓ Infrastructure deployed successfully"
else
    echo "Infrastructure deployment cancelled."
    exit 1
fi

echo ""
echo "=== Step 2: Waiting for Cluster to be Ready ==="
echo "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo ""
echo "=== Cluster Setup Complete ==="
echo "Kubeconfig saved to: $PROJECT_ROOT/kubeconfig"
echo ""
echo "To use this cluster, run:"
echo "  export KUBECONFIG=$PROJECT_ROOT/kubeconfig"
echo ""
echo "Next steps:"
echo "  1. Run ./scripts/deploy-all.sh to install all services"
echo "  2. Or deploy services individually from helm/<service>/deploy.sh"
echo ""
