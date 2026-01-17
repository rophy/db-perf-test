#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== YugabyteDB Test Infrastructure Setup (minikube) ==="

# Check prerequisites
command -v minikube >/dev/null 2>&1 || { echo "minikube is required but not installed. Aborting." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed. Aborting." >&2; exit 1; }

# Start minikube if not running
if ! minikube status | grep -q "Running"; then
    echo "Starting minikube with recommended resources..."
    minikube start --cpus=4 --memory=8192 --disk-size=50g
fi

# Enable required addons
echo "Enabling minikube addons..."
minikube addons enable metrics-server
minikube addons enable storage-provisioner

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
    --wait

# Install YugabyteDB
echo "Installing YugabyteDB..."
helm repo add yugabytedb https://charts.yugabyte.com || true
helm repo update
helm upgrade --install yugabyte yugabytedb/yugabyte \
    --namespace yugabyte-test \
    --values "$PROJECT_DIR/k8s/overlays/minikube/yugabytedb-values.yaml" \
    --wait --timeout 10m

echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Wait for all pods to be ready: kubectl get pods -n yugabyte-test -w"
echo "  2. Deploy Kafka and other components: make deploy ENV=minikube"
echo "  3. Access Prometheus: minikube service prometheus -n yugabyte-test"
