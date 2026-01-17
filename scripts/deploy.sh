#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

ENV="${ENV:-minikube}"
KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"

echo "=== Deploying YugabyteDB Test Components (env: $ENV) ==="
echo "Context: $KUBE_CONTEXT"

# Apply Kustomize overlay
echo "Applying Kubernetes manifests..."
kubectl --context "$KUBE_CONTEXT" apply -k "$PROJECT_DIR/k8s/overlays/$ENV"

# Wait for Kafka to be ready
echo "Waiting for Kafka cluster to be ready..."
kubectl --context "$KUBE_CONTEXT" wait kafka/kafka-cluster --for=condition=Ready --timeout=300s -n yugabyte-test || true

# Apply sink connectors (after Kafka Connect is ready)
echo "Waiting for Kafka Connect to be ready..."
kubectl --context "$KUBE_CONTEXT" wait kafkaconnect/kafka-connect --for=condition=Ready --timeout=300s -n yugabyte-test || true

echo "Applying JDBC sink connectors..."
kubectl --context "$KUBE_CONTEXT" apply -f "$PROJECT_DIR/sink/jdbc-sink-connector.yaml"

# Initialize YugabyteDB schema
echo "Initializing YugabyteDB schema..."
YSQL_POD=$(kubectl --context "$KUBE_CONTEXT" get pod -l app=yb-tserver -n yugabyte-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$YSQL_POD" ]; then
    kubectl --context "$KUBE_CONTEXT" cp "$PROJECT_DIR/sink/init-schema.sql" "yugabyte-test/$YSQL_POD:/tmp/init-schema.sql"
    kubectl --context "$KUBE_CONTEXT" exec -n yugabyte-test "$YSQL_POD" -- /home/yugabyte/bin/ysqlsh -h localhost -c "\i /tmp/init-schema.sql" || true
fi

echo "=== Deployment Complete ==="
echo ""
echo "Check status with:"
echo "  kubectl --context $KUBE_CONTEXT get pods -n yugabyte-test"
echo "  kubectl --context $KUBE_CONTEXT get kafkatopics -n yugabyte-test"
echo "  kubectl --context $KUBE_CONTEXT get kafkaconnectors -n yugabyte-test"
