#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Cluster configuration - must be provided for AWS
KUBE_CONTEXT="${KUBE_CONTEXT:?KUBE_CONTEXT must be set to the AWS cluster context}"

echo "=== YugabyteDB Benchmark Infrastructure Setup (AWS) ==="
echo "Context: $KUBE_CONTEXT"

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed. Aborting." >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "aws CLI is required but not installed. Aborting." >&2; exit 1; }

# Verify kubectl context exists
if ! kubectl config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1; then
    echo "Context '$KUBE_CONTEXT' not found. Please configure kubectl first."
    exit 1
fi

echo "Using kubectl context: $KUBE_CONTEXT"
read -p "Is this the correct AWS cluster? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Create namespace
echo "Creating namespace..."
kubectl --context "$KUBE_CONTEXT" apply -f "$PROJECT_DIR/k8s/base/namespace.yaml"

# Install YugabyteDB
echo "Installing YugabyteDB..."
helm repo add yugabytedb https://charts.yugabyte.com || true
helm repo update
helm upgrade --install yugabyte yugabytedb/yugabyte \
    --kube-context "$KUBE_CONTEXT" \
    --namespace yugabyte-test \
    --values "$PROJECT_DIR/k8s/overlays/aws/yugabytedb-values.yaml" \
    --wait --timeout 15m

echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Wait for YugabyteDB pods to be ready:"
echo "     kubectl --context $KUBE_CONTEXT get pods -n yugabyte-test -w"
echo "  2. Deploy HammerDB and Prometheus:"
echo "     KUBE_CONTEXT=$KUBE_CONTEXT make deploy ENV=aws"
echo "  3. Build TPROC-C schema:"
echo "     KUBE_CONTEXT=$KUBE_CONTEXT make build-schema"
echo "  4. Run benchmark:"
echo "     KUBE_CONTEXT=$KUBE_CONTEXT make run-bench"
