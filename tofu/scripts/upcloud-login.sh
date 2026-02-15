#!/bin/bash

# UpCloud Environment Setup
# 
# USAGE: Source this script to load environment variables into your current shell:
#   source upcloud-login.sh
#   OR
#   . upcloud-login.sh
#
# DO NOT run with ./upcloud-login.sh (variables won't persist)
#
# SETUP: Create a .env file in this directory with:
#   UPCLOUD_TOKEN=your-token-here
#   UPCLOUD_CLUSTER_ID=your-cluster-id

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

echo "🔧 Setting up UpCloud environment..."

# Load from .env file if it exists
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
    echo "✓ Loaded credentials from .env"
elif [ -z "$UPCLOUD_TOKEN" ]; then
    echo "❌ Error: No .env file found and UPCLOUD_TOKEN not set"
    echo "   Create ${ENV_FILE} with UPCLOUD_TOKEN and UPCLOUD_CLUSTER_ID"
    return 1
fi

KUBECONFIG_FILE="upcloud_kubeconfig_${UPCLOUD_CLUSTER_ID}.yaml"

# Validate token is set
if [ -z "$UPCLOUD_TOKEN" ]; then
    echo "❌ Error: UPCLOUD_TOKEN is not set"
    return 1
fi
export UPCLOUD_TOKEN
echo "✓ UpCloud token configured"

# if cluster ID is not set, return with a message and return
if [ -z "$UPCLOUD_CLUSTER_ID" ]; then
    echo "⚠️  UPCLOUD_CLUSTER_ID is not set. Please set it in the script before running."
    echo "Example: UPCLOUD_CLUSTER_ID=\"your-cluster-id\""
    return 1
fi

# Get Kubernetes cluster config if not already present
if [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "📥 Downloading Kubernetes config..."
    upctl kubernetes config "$UPCLOUD_CLUSTER_ID" --write "$KUBECONFIG_FILE"
    echo "✓ Kubeconfig downloaded: $KUBECONFIG_FILE"
else
    echo "✓ Using existing kubeconfig: $KUBECONFIG_FILE"
fi

# Set KUBECONFIG environment variable
export KUBECONFIG="$(pwd)/$KUBECONFIG_FILE"
echo "✓ KUBECONFIG environment variable set"
echo "✅ Setup complete! Ready to use kubectl and k9s"
