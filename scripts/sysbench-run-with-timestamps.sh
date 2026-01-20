#!/bin/bash
set -e

# Wrapper script to run sysbench with timestamp recording for report generation
# Runs sysbench directly with flags passed from Makefile

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
RELEASE_NAME="${RELEASE_NAME:-yb-bench}"
SYSBENCH_WORKLOAD="${SYSBENCH_WORKLOAD:-oltp_read_write}"
SYSBENCH_RUN_OPTS="${SYSBENCH_RUN_OPTS:-}"

# Create output directory
OUTPUT_DIR="${PROJECT_ROOT}/output/sysbench"
mkdir -p "$OUTPUT_DIR"

echo "=== Sysbench Benchmark Runner ==="
echo "Workload: ${SYSBENCH_WORKLOAD}"
echo "Options: ${SYSBENCH_RUN_OPTS}"
echo ""

# Record start time
START_TIME=$(date +%s)
echo "$START_TIME" > "${OUTPUT_DIR}/RUN_START_TIME.txt"
echo "Start time: $(date -d @${START_TIME} '+%Y-%m-%d %H:%M:%S')"
echo ""

# Run sysbench directly
kubectl --context "${KUBE_CONTEXT}" exec -n "${NAMESPACE}" deployment/${RELEASE_NAME}-sysbench -- \
    sysbench ${SYSBENCH_WORKLOAD} ${SYSBENCH_RUN_OPTS} run | tee "${OUTPUT_DIR}/sysbench_output.txt"

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
