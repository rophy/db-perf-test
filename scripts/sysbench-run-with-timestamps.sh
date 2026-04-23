#!/bin/bash
set -e

# Wrapper script to run sysbench with timestamp recording for report generation.
# Supports multiple sysbench pods (StatefulSet replicas) — runs them in parallel,
# then merges output into a single sysbench_output.txt for the report pipeline.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
RELEASE_NAME="${RELEASE_NAME:-yb-benchmark}"

OUTPUT_DIR="${PROJECT_ROOT}/output"
mkdir -p "$OUTPUT_DIR"

KUBECTL="kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE}"

echo "=== Sysbench Benchmark Runner ==="
echo "Context: ${KUBE_CONTEXT}"
echo "Namespace: ${NAMESPACE}"
echo ""

# Discover sysbench pods
PODS=($($KUBECTL get pods -l "app.kubernetes.io/component=sysbench" \
    -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort))
NUM_PODS=${#PODS[@]}

if [[ $NUM_PODS -eq 0 ]]; then
    echo "ERROR: No sysbench pods found" >&2
    exit 1
fi

echo "Sysbench pods (${NUM_PODS}): ${PODS[*]}"
echo ""

# Collect tserver pod-to-node mapping with node allocatable specs
echo "Collecting node specs..."
echo -e "pod_name\tnode_name\tcpu\tmemory" > "${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
for pod in $($KUBECTL get pods -l app=yb-tserver -o jsonpath='{.items[*].metadata.name}'); do
    node=$($KUBECTL get pod "$pod" -o jsonpath='{.spec.nodeName}')
    read -r cpu mem <<< "$(kubectl --context "${KUBE_CONTEXT}" get node "$node" -o jsonpath='{.status.allocatable.cpu} {.status.allocatable.memory}')"
    echo -e "${pod}\t${node}\t${cpu}\t${mem}" >> "${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
done

# Collect sysbench pod-to-node mapping
echo -e "pod_name\tnode_name" > "${OUTPUT_DIR}/CLIENT_NODE_SPEC.txt"
for pod in "${PODS[@]}"; do
    node=$($KUBECTL get pod "$pod" -o jsonpath='{.spec.nodeName}')
    echo -e "${pod}\t${node}" >> "${OUTPUT_DIR}/CLIENT_NODE_SPEC.txt"
done
echo "Node specs saved."
echo ""

# Read warmup-time from the live sysbench configmap
SYSBENCH_CM=$($KUBECTL get cm -l app.kubernetes.io/component=sysbench \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$SYSBENCH_CM" ]]; then
    SYSBENCH_CM="${RELEASE_NAME}-sysbench-scripts"
    echo "Warning: could not discover sysbench configmap, falling back to ${SYSBENCH_CM}"
fi
WARMUP_TIME=$($KUBECTL get cm "$SYSBENCH_CM" \
    -o jsonpath='{.data.sysbench-run\.sh}' 2>/dev/null \
    | grep -oE -- '--warmup-time=[0-9]+' | head -1 | cut -d= -f2)
if [[ -z "$WARMUP_TIME" ]]; then
    echo "Error: could not read --warmup-time from configmap ${SYSBENCH_CM}" >&2
    exit 1
fi

# Record start time
START_TIME=$(date +%s)
WARMUP_END_TIME=$(( START_TIME + WARMUP_TIME ))
TIMES_FILE="${OUTPUT_DIR}/test_times.txt"
{
    echo "WORKLOAD_TYPE=sysbench"
    echo "RUN_START_TIME=${START_TIME}"
    echo "WARMUP_END_TIME=${WARMUP_END_TIME}"
    echo "NUM_SYSBENCH_PODS=${NUM_PODS}"
} > "$TIMES_FILE"
echo "Start time:       $(date -d @${START_TIME} '+%Y-%m-%d %H:%M:%S')"
echo "Warmup ends at:   $(date -d @${WARMUP_END_TIME} '+%Y-%m-%d %H:%M:%S') (warmup=${WARMUP_TIME}s)"
echo "Pods: ${NUM_PODS}"
echo ""

# Launch sysbench on all pods in parallel
PIDS=()
for i in "${!PODS[@]}"; do
    pod="${PODS[$i]}"
    outfile="${OUTPUT_DIR}/sysbench_output_${i}.txt"
    if [[ $i -eq 0 ]]; then
        # Pod-0: tee to stdout for live progress
        $KUBECTL exec "${pod}" -- /scripts/sysbench-run.sh 2>&1 | tee "${outfile}" &
    else
        $KUBECTL exec "${pod}" -- /scripts/sysbench-run.sh > "${outfile}" 2>&1 &
    fi
    PIDS+=($!)
done

echo "Launched ${NUM_PODS} sysbench process(es). Waiting..."

# Wait for all pods and check exit codes
FAILED=0
for i in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$i]}"; then
        echo "ERROR: Sysbench on ${PODS[$i]} failed (exit code $?)" >&2
        FAILED=1
    fi
done

if [[ $FAILED -ne 0 ]]; then
    echo "ERROR: One or more sysbench pods failed" >&2
    exit 1
fi

# Record end time
END_TIME=$(date +%s)
echo "RUN_END_TIME=${END_TIME}" >> "$TIMES_FILE"
echo ""
echo "End time: $(date -d @${END_TIME} '+%Y-%m-%d %H:%M:%S')"
echo "Duration: $(( (END_TIME - START_TIME) / 60 )) minutes $(( (END_TIME - START_TIME) % 60 )) seconds"

# Merge outputs
INPUT_FILES=()
for i in "${!PODS[@]}"; do
    INPUT_FILES+=("${OUTPUT_DIR}/sysbench_output_${i}.txt")
done

if [[ $NUM_PODS -gt 1 ]]; then
    echo ""
    echo "Merging ${NUM_PODS} sysbench outputs..."
    python3 "${PROJECT_ROOT}/scripts/merge-sysbench-output.py" \
        "${INPUT_FILES[@]}" -o "${OUTPUT_DIR}/sysbench_output.txt"
else
    cp "${INPUT_FILES[0]}" "${OUTPUT_DIR}/sysbench_output.txt"
fi

echo ""
echo "=== Benchmark Complete ==="
echo "Output saved to: ${OUTPUT_DIR}"
echo "Run 'make report' to generate the performance report."
