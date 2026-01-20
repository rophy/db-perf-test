#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"

echo "=== Deploying YugabyteDB Benchmark Components ==="
echo "Context: $KUBE_CONTEXT"

# Apply flat manifests
echo "Applying Kubernetes manifests..."
kubectl --context "$KUBE_CONTEXT" apply -f "$PROJECT_DIR/k8s/namespace.yaml"
kubectl --context "$KUBE_CONTEXT" apply -f "$PROJECT_DIR/k8s/sysbench.yaml"
kubectl --context "$KUBE_CONTEXT" apply -f "$PROJECT_DIR/k8s/hammerdb.yaml"
kubectl --context "$KUBE_CONTEXT" apply -f "$PROJECT_DIR/k8s/prometheus.yaml"

# Wait for deployments
echo "Waiting for sysbench deployment..."
kubectl --context "$KUBE_CONTEXT" rollout status deployment/sysbench -n yugabyte-test --timeout=120s || true

echo "Waiting for HammerDB deployment..."
kubectl --context "$KUBE_CONTEXT" rollout status deployment/hammerdb -n yugabyte-test --timeout=120s || true

echo "Waiting for Prometheus deployment..."
kubectl --context "$KUBE_CONTEXT" rollout status deployment/prometheus -n yugabyte-test --timeout=120s || true

echo "=== Deployment Complete ==="
echo ""
echo "Check status:"
echo "  kubectl --context $KUBE_CONTEXT get pods -n yugabyte-test"
echo ""
echo "Deploy YugabyteDB:"
echo "  helm install yugabyte yugabytedb/yugabyte -n yugabyte-test -f k8s/yugabytedb-values.yaml"
