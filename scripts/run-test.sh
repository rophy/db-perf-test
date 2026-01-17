#!/bin/bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
EVENTS_PER_SECOND="${1:-1000}"
THREADS="${2:-4}"
MODE="${3:-both}"  # oracle, db2, or both

echo "=== Running CDC Producer Test ==="
echo "Context: $KUBE_CONTEXT"
echo "Events/sec: $EVENTS_PER_SECOND"
echo "Threads: $THREADS"
echo "Mode: $MODE"

# Update producer deployment with new settings
kubectl --context "$KUBE_CONTEXT" set env deployment/cdc-producer -n yugabyte-test \
    PRODUCER_EVENTS_PER_SECOND="$EVENTS_PER_SECOND" \
    PRODUCER_THREADS="$THREADS" \
    PRODUCER_MODE="$MODE"

# Restart producer to apply changes
kubectl --context "$KUBE_CONTEXT" rollout restart deployment/cdc-producer -n yugabyte-test
kubectl --context "$KUBE_CONTEXT" rollout status deployment/cdc-producer -n yugabyte-test

echo ""
echo "Producer restarted with new settings."
echo ""
echo "Monitor with:"
echo "  kubectl --context $KUBE_CONTEXT logs -f deployment/cdc-producer -n yugabyte-test"
echo "  kubectl --context $KUBE_CONTEXT port-forward svc/prometheus 9090:9090 -n yugabyte-test"
