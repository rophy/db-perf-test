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

# Read warmup-time from the live sysbench configmap so WARMUP_END_TIME is in sync with the run.
WARMUP_TIME=$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get cm "${RELEASE_NAME}-sysbench-scripts" \
    -o jsonpath='{.data.sysbench-run\.sh}' 2>/dev/null \
    | grep -oE -- '--warmup-time=[0-9]+' | head -1 | cut -d= -f2)
if [[ -z "$WARMUP_TIME" ]]; then
    echo "Error: could not read --warmup-time from configmap ${RELEASE_NAME}-sysbench-scripts" >&2
    exit 1
fi

# Record start time
START_TIME=$(date +%s)
WARMUP_END_TIME=$(( START_TIME + WARMUP_TIME ))
TIMES_FILE="${OUTPUT_DIR}/sysbench_times.txt"
{
    echo "RUN_START_TIME=${START_TIME}"
    echo "WARMUP_END_TIME=${WARMUP_END_TIME}"
} > "$TIMES_FILE"
echo "Start time:       $(date -d @${START_TIME} '+%Y-%m-%d %H:%M:%S')"
echo "Warmup ends at:   $(date -d @${WARMUP_END_TIME} '+%Y-%m-%d %H:%M:%S') (warmup=${WARMUP_TIME}s)"
echo ""

# Run sysbench via in-cluster script (parameters from Helm values)
kubectl --context "${KUBE_CONTEXT}" exec -n "${NAMESPACE}" deployment/${RELEASE_NAME}-sysbench -- \
    /scripts/sysbench-run.sh | tee "${OUTPUT_DIR}/sysbench_output.txt"

# Record end time
END_TIME=$(date +%s)
echo "RUN_END_TIME=${END_TIME}" >> "$TIMES_FILE"
echo ""
echo "End time: $(date -d @${END_TIME} '+%Y-%m-%d %H:%M:%S')"
echo "Duration: $(( (END_TIME - START_TIME) / 60 )) minutes $(( (END_TIME - START_TIME) % 60 )) seconds"

echo ""
echo "=== Benchmark Complete ==="
echo "Output saved to: ${OUTPUT_DIR}"
echo "Run 'make report' to generate the performance report."
