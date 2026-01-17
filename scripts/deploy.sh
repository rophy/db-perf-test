#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

ENV="${ENV:-minikube}"
KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"

echo "=== Deploying YugabyteDB Benchmark Components (env: $ENV) ==="
echo "Context: $KUBE_CONTEXT"

# Apply Kustomize overlay
echo "Applying Kubernetes manifests..."
kubectl --context "$KUBE_CONTEXT" apply -k "$PROJECT_DIR/k8s/overlays/$ENV"

# Wait for HammerDB to be ready
echo "Waiting for HammerDB deployment to be ready..."
kubectl --context "$KUBE_CONTEXT" rollout status deployment/hammerdb -n yugabyte-test --timeout=120s || true

# Wait for Prometheus to be ready
echo "Waiting for Prometheus deployment to be ready..."
kubectl --context "$KUBE_CONTEXT" rollout status deployment/prometheus -n yugabyte-test --timeout=120s || true

echo "=== Deployment Complete ==="
echo ""
echo "Check status with:"
echo "  kubectl --context $KUBE_CONTEXT get pods -n yugabyte-test"
echo ""
echo "Build TPROC-C schema:"
echo "  make build-schema"
echo ""
echo "Run benchmark:"
echo "  make run-bench"
