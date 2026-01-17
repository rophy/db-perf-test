#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

KUBE_CONTEXT="minikube"

echo "=== YugabyteDB Benchmark Infrastructure Setup (minikube) ==="

# Check prerequisites
command -v minikube >/dev/null 2>&1 || { echo "minikube is required but not installed. Aborting." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed. Aborting." >&2; exit 1; }

# Start minikube if not running
# Recommended: 4 CPUs, 5GB RAM per https://docs.yugabyte.com/stable/deploy/kubernetes/single-zone/oss/helm-chart/
if ! minikube status | grep -q "Running"; then
    echo "Starting minikube with recommended resources (4 CPUs, 5GB RAM)..."
    minikube start --cpus=4 --memory=5120
fi

# Enable required addons
echo "Enabling minikube addons..."
minikube addons enable metrics-server
minikube addons enable storage-provisioner

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
    --values "$PROJECT_DIR/k8s/overlays/minikube/yugabytedb-values.yaml"

echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Wait for YugabyteDB pods to be ready:"
echo "     kubectl --context $KUBE_CONTEXT get pods -n yugabyte-test -w"
echo "  2. Deploy HammerDB and Prometheus:"
echo "     make deploy ENV=minikube"
echo "  3. Build TPROC-C schema:"
echo "     make build-schema"
echo "  4. Run benchmark:"
echo "     make run-bench"
