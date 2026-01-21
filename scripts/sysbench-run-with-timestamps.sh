#!/bin/bash
set -e

# Wrapper script to run sysbench with timestamp recording for report generation
# Uses in-cluster script from ConfigMap (parameters defined in Helm values)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
RELEASE_NAME="${RELEASE_NAME:-yb-bench}"

# Create output directory
OUTPUT_DIR="${PROJECT_ROOT}/output/sysbench"
mkdir -p "$OUTPUT_DIR"

echo "=== Sysbench Benchmark Runner ==="
echo "Context: ${KUBE_CONTEXT}"
echo "Namespace: ${NAMESPACE}"
echo ""

# Collect tserver pod to node mapping with node allocatable specs
echo "Collecting node specs..."
echo -e "pod_name\tnode_name\tcpu\tmemory" > "${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
for pod in $(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=yb-tserver -o jsonpath='{.items[*].metadata.name}'); do
    node=$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod "$pod" -o jsonpath='{.spec.nodeName}')
    read -r cpu mem <<< "$(kubectl --context "${KUBE_CONTEXT}" get node "$node" -o jsonpath='{.status.allocatable.cpu} {.status.allocatable.memory}')"
    echo -e "${pod}\t${node}\t${cpu}\t${mem}" >> "${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
done
echo "Node specs saved to: ${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
echo ""

# Record start time
START_TIME=$(date +%s)
echo "$START_TIME" > "${OUTPUT_DIR}/RUN_START_TIME.txt"
echo "Start time: $(date -d @${START_TIME} '+%Y-%m-%d %H:%M:%S')"
echo ""

# Run sysbench via in-cluster script (parameters from Helm values)
kubectl --context "${KUBE_CONTEXT}" exec -n "${NAMESPACE}" deployment/${RELEASE_NAME}-sysbench -- \
    /scripts/sysbench-run.sh | tee "${OUTPUT_DIR}/sysbench_output.txt"

# Record end time
END_TIME=$(date +%s)
echo "$END_TIME" > "${OUTPUT_DIR}/RUN_END_TIME.txt"
echo ""
echo "End time: $(date -d @${END_TIME} '+%Y-%m-%d %H:%M:%S')"
echo "Duration: $(( (END_TIME - START_TIME) / 60 )) minutes $(( (END_TIME - START_TIME) % 60 )) seconds"

echo ""
echo "=== Benchmark Complete ==="
echo "Output saved to: ${OUTPUT_DIR}"
echo "Run 'make report' to generate the performance report."
