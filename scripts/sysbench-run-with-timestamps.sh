#!/bin/bash
set -e

# Wrapper script to run sysbench with timestamp recording for report generation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration from environment
KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
SYSBENCH_TABLES="${SYSBENCH_TABLES:-1}"
SYSBENCH_TABLE_SIZE="${SYSBENCH_TABLE_SIZE:-1000}"
SYSBENCH_THREADS="${SYSBENCH_THREADS:-1}"
SYSBENCH_TIME="${SYSBENCH_TIME:-60}"
SYSBENCH_WARMUP="${SYSBENCH_WARMUP:-10}"
SYSBENCH_WORKLOAD="${SYSBENCH_WORKLOAD:-oltp_read_write}"

# Create output directory
OUTPUT_DIR="${PROJECT_ROOT}/output/sysbench"
mkdir -p "$OUTPUT_DIR"

echo "=== Sysbench Benchmark Runner ==="
echo "Tables: ${SYSBENCH_TABLES}, Size: ${SYSBENCH_TABLE_SIZE}"
echo "Threads: ${SYSBENCH_THREADS}, Duration: ${SYSBENCH_TIME}s"
echo ""

# Record start time
START_TIME=$(date +%s)
echo "$START_TIME" > "${OUTPUT_DIR}/RUN_START_TIME.txt"
echo "Start time: $(date -d @${START_TIME} '+%Y-%m-%d %H:%M:%S')"

# Run sysbench
echo ""
echo "Running sysbench benchmark..."
kubectl --context "${KUBE_CONTEXT}" exec -n yugabyte-test deployment/sysbench -- \
    env SYSBENCH_TABLES="${SYSBENCH_TABLES}" \
        SYSBENCH_TABLE_SIZE="${SYSBENCH_TABLE_SIZE}" \
        SYSBENCH_THREADS="${SYSBENCH_THREADS}" \
        SYSBENCH_TIME="${SYSBENCH_TIME}" \
        SYSBENCH_WARMUP="${SYSBENCH_WARMUP}" \
        SYSBENCH_WORKLOAD="${SYSBENCH_WORKLOAD}" \
    /scripts/entrypoint.sh run | tee "${OUTPUT_DIR}/sysbench_output.txt"

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
