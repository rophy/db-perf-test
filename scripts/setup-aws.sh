#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== YugabyteDB Test Infrastructure Setup (AWS) ==="

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed. Aborting." >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "aws CLI is required but not installed. Aborting." >&2; exit 1; }

# Verify kubectl context
CURRENT_CONTEXT=$(kubectl config current-context)
echo "Using kubectl context: $CURRENT_CONTEXT"
read -p "Is this the correct AWS cluster? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Please configure kubectl to use the correct cluster and re-run."
    exit 1
fi

# Create namespace
echo "Creating namespace..."
kubectl apply -f "$PROJECT_DIR/k8s/base/namespace.yaml"

# Install Strimzi Operator
echo "Installing Strimzi Kafka Operator..."
helm repo add strimzi https://strimzi.io/charts/ || true
helm repo update
helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
    --namespace yugabyte-test \
    --version 0.38.0 \
    --set resources.requests.cpu=500m \
    --set resources.requests.memory=512Mi \
    --set resources.limits.cpu=1 \
    --set resources.limits.memory=1Gi \
    --wait

# Install YugabyteDB
echo "Installing YugabyteDB..."
helm repo add yugabytedb https://charts.yugabyte.com || true
helm repo update
helm upgrade --install yugabyte yugabytedb/yugabyte \
    --namespace yugabyte-test \
    --values "$PROJECT_DIR/k8s/overlays/aws/yugabytedb-values.yaml" \
    --wait --timeout 15m

echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Wait for all pods to be ready: kubectl get pods -n yugabyte-test -w"
echo "  2. Deploy Kafka and other components: make deploy ENV=aws"
echo "  3. Get Prometheus URL: kubectl get svc prometheus -n yugabyte-test"
