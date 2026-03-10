#!/bin/bash
set -euo pipefail

KUBE_CONTEXT="minikube"
NODES=4
CPUS=4
MEMORY=8192

echo "=== YugabyteDB Benchmark Infrastructure Setup (minikube multi-node) ==="
echo "Cluster: $NODES nodes x $CPUS CPUs x ${MEMORY}MB RAM"

# Check prerequisites
command -v minikube >/dev/null 2>&1 || { echo "minikube is required but not installed. Aborting." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed. Aborting." >&2; exit 1; }

# Start minikube if not running
if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q "Running"; then
    echo "Starting minikube with $NODES nodes ($CPUS CPUs, ${MEMORY}MB RAM each)..."
    minikube start --driver=kvm2 --nodes=$NODES --cpus=$CPUS --memory=$MEMORY
else
    echo "minikube is already running."
fi

# Enable required addons
echo "Enabling minikube addons..."
minikube addons enable metrics-server
minikube addons enable storage-provisioner

# Label nodes for scheduling:
#   minikube       -> role=master (YB masters, sysbench, prometheus)
#   minikube-m0N   -> role=db     (one tserver each)
echo "Labeling nodes..."
kubectl --context "$KUBE_CONTEXT" label node minikube role=master --overwrite
for i in 2 3 4; do
    kubectl --context "$KUBE_CONTEXT" label node "minikube-m0${i}" role=db --overwrite
done

echo ""
echo "=== Node Layout ==="
kubectl --context "$KUBE_CONTEXT" get nodes -L role
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Deploy the full stack:"
echo "     make deploy-minikube"
echo "  2. Wait for pods to be ready:"
echo "     make status"
echo "  3. Prepare sysbench tables:"
echo "     make sysbench-prepare"
echo "  4. Run benchmark:"
echo "     make sysbench-run"
