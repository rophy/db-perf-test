#!/bin/bash
set -e

# Wrapper script to run k6 with timestamp recording for report generation.
# Mirrors sysbench-run-with-timestamps.sh output format so the report pipeline
# can handle both workloads.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
RELEASE_NAME="${RELEASE_NAME:-yb-bench}"
K6_SCRIPT="${K6_SCRIPT:-test.js}"

OUTPUT_DIR="${PROJECT_ROOT}/output/k6"
mkdir -p "$OUTPUT_DIR"

KUBECTL="kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE}"

echo "=== k6 Benchmark Runner ==="
echo "Context: ${KUBE_CONTEXT}"
echo "Namespace: ${NAMESPACE}"
echo "Script: ${K6_SCRIPT}"
echo ""

# Discover k6 pods
PODS=($($KUBECTL get pods -l "app.kubernetes.io/component=k6" \
    -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort))
NUM_PODS=${#PODS[@]}

if [[ $NUM_PODS -eq 0 ]]; then
    echo "ERROR: No k6 pods found" >&2
    exit 1
fi

echo "k6 pods (${NUM_PODS}): ${PODS[*]}"
echo ""

# Collect tserver pod-to-node mapping with node allocatable specs
echo "Collecting node specs..."
echo -e "pod_name\tnode_name\tcpu\tmemory" > "${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
for pod in $($KUBECTL get pods -l app=yb-tserver -o jsonpath='{.items[*].metadata.name}'); do
    node=$($KUBECTL get pod "$pod" -o jsonpath='{.spec.nodeName}')
    read -r cpu mem <<< "$(kubectl --context "${KUBE_CONTEXT}" get node "$node" -o jsonpath='{.status.allocatable.cpu} {.status.allocatable.memory}')"
    echo -e "${pod}\t${node}\t${cpu}\t${mem}" >> "${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
done

# Collect k6 pod-to-node mapping
echo -e "pod_name\tnode_name" > "${OUTPUT_DIR}/K6_NODE_SPEC.txt"
for pod in "${PODS[@]}"; do
    node=$($KUBECTL get pod "$pod" -o jsonpath='{.spec.nodeName}')
    echo -e "${pod}\t${node}" >> "${OUTPUT_DIR}/K6_NODE_SPEC.txt"
done
echo "Node specs saved."
echo ""

# Read warmup time from k6 pod env
WARMUP_TIME=$($KUBECTL get pod "${PODS[0]}" \
    -o jsonpath='{.spec.containers[0].env[?(@.name=="BENCH_WARMUP")].value}' 2>/dev/null)
WARMUP_TIME="${WARMUP_TIME:-0}"

# Record start time
START_TIME=$(date +%s)
WARMUP_END_TIME=$(( START_TIME + WARMUP_TIME ))
TIMES_FILE="${OUTPUT_DIR}/k6_times.txt"
{
    echo "WORKLOAD_TYPE=k6"
    echo "RUN_START_TIME=${START_TIME}"
    echo "WARMUP_END_TIME=${WARMUP_END_TIME}"
    echo "NUM_K6_PODS=${NUM_PODS}"
} > "$TIMES_FILE"
echo "Start time:       $(date -d @${START_TIME} '+%Y-%m-%d %H:%M:%S')"
echo "Warmup ends at:   $(date -d @${WARMUP_END_TIME} '+%Y-%m-%d %H:%M:%S') (warmup=${WARMUP_TIME}s)"
echo "Pods: ${NUM_PODS}"
echo ""

# Launch k6 on all pods in parallel
PIDS=()
for i in "${!PODS[@]}"; do
    pod="${PODS[$i]}"
    outfile="${OUTPUT_DIR}/k6_output_${i}.txt"
    if [[ $i -eq 0 ]]; then
        $KUBECTL exec "${pod}" -- k6 run --out experimental-prometheus-rw "/scripts/${K6_SCRIPT}" 2>&1 | tee "${outfile}" &
    else
        $KUBECTL exec "${pod}" -- k6 run --out experimental-prometheus-rw "/scripts/${K6_SCRIPT}" > "${outfile}" 2>&1 &
    fi
    PIDS+=($!)
done

echo "Launched ${NUM_PODS} k6 process(es). Waiting..."

# Wait for all pods and check exit codes
FAILED=0
for i in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$i]}"; then
        echo "ERROR: k6 on ${PODS[$i]} failed (exit code $?)" >&2
        FAILED=1
    fi
done

if [[ $FAILED -ne 0 ]]; then
    echo "ERROR: One or more k6 pods failed" >&2
    exit 1
fi

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
