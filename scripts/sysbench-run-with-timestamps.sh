#!/bin/bash
set -e

# Wrapper script to run sysbench with timestamp recording for report generation
# Uses the entrypoint script which has all YugabyteDB-optimized flags

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"

# Create output directory
OUTPUT_DIR="${PROJECT_ROOT}/output/sysbench"
mkdir -p "$OUTPUT_DIR"

echo "=== Sysbench Benchmark Runner ==="
echo "Using entrypoint script with YugabyteDB-optimized flags"
echo ""

# Show current config
kubectl --context "${KUBE_CONTEXT}" exec -n yugabyte-test deployment/sysbench -- \
    /scripts/entrypoint.sh config

echo ""

# Record start time
START_TIME=$(date +%s)
echo "$START_TIME" > "${OUTPUT_DIR}/RUN_START_TIME.txt"
echo "Start time: $(date -d @${START_TIME} '+%Y-%m-%d %H:%M:%S')"
echo ""

# Run sysbench via entrypoint (includes all YugabyteDB flags)
kubectl --context "${KUBE_CONTEXT}" exec -n yugabyte-test deployment/sysbench -- \
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
