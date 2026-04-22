#!/bin/bash
set -e

# Report generation script for benchmark stress tests (sysbench or k6)
# Auto-detects workload type from timestamps file and generates HTML report

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
RELEASE_NAME="${RELEASE_NAME:-yb-bench}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/reports}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://${RELEASE_NAME}-prometheus:9090}"
METRICS_DUMP_BASE_URL="${METRICS_DUMP_BASE_URL:-}"

# Read timestamps from unified output directory
TIMES_FILE="${PROJECT_ROOT}/output/test_times.txt"

if [[ ! -f "$TIMES_FILE" ]]; then
    echo "Error: timestamp file not found: $TIMES_FILE"
    echo "Run 'make sysbench-run' or 'make k6-run' first."
    exit 1
fi

# Read workload type (defaults to sysbench for backward compat)
WORKLOAD_TYPE=$(grep -E '^WORKLOAD_TYPE=' "$TIMES_FILE" 2>/dev/null | cut -d= -f2)
WORKLOAD_TYPE="${WORKLOAD_TYPE:-sysbench}"

START_TIME=$(grep -E '^RUN_START_TIME=' "$TIMES_FILE" | cut -d= -f2)
WARMUP_END_TIME=$(grep -E '^WARMUP_END_TIME=' "$TIMES_FILE" | cut -d= -f2)
END_TIME=$(grep -E '^RUN_END_TIME=' "$TIMES_FILE" | cut -d= -f2)

if [[ -z "$START_TIME" || -z "$END_TIME" ]]; then
    echo "Error: RUN_START_TIME or RUN_END_TIME missing in $TIMES_FILE"
    echo "The benchmark may still be running or failed to complete."
    exit 1
fi

# Set title and pod patterns based on workload type
if [[ "$WORKLOAD_TYPE" == "k6" ]]; then
    REPORT_TITLE="k6 Stress Test Report"
    POD_PATTERNS=("yb-tserver.*" "yb-master.*" "k6.*")
else
    REPORT_TITLE="Sysbench Stress Test Report"
    POD_PATTERNS=("yb-tserver.*" "yb-master.*" "sysbench.*")
fi

echo "=== ${WORKLOAD_TYPE} Report Generator ==="
echo "Start time:  $(date -d @${START_TIME} '+%Y-%m-%d %H:%M:%S')"
if [[ -n "$WARMUP_END_TIME" ]]; then
    echo "Warmup ends: $(date -d @${WARMUP_END_TIME} '+%Y-%m-%d %H:%M:%S')"
fi
echo "End time:    $(date -d @${END_TIME} '+%Y-%m-%d %H:%M:%S')"
echo "Duration: $(( (END_TIME - START_TIME) / 60 )) minutes"
echo ""

# Execute
echo "Generating report..."
PYTHON_ARGS=(
    --start "$START_TIME"
    --end "$END_TIME"
    --kube-context "$KUBE_CONTEXT"
    --namespace "$NAMESPACE"
    --release-name "$RELEASE_NAME"
    --prometheus-url "$PROMETHEUS_URL"
    --output-dir "$OUTPUT_DIR"
    --title "$REPORT_TITLE"
    --pods "${POD_PATTERNS[@]}"
    --workload-type "$WORKLOAD_TYPE"
    --metrics-dump-base-url "$METRICS_DUMP_BASE_URL"
)
if [[ -n "$WARMUP_END_TIME" ]]; then
    PYTHON_ARGS+=(--warmup-end "$WARMUP_END_TIME")
fi
REPORT_OUTPUT=$(python3 "${SCRIPT_DIR}/generate_report.py" "${PYTHON_ARGS[@]}")

echo "$REPORT_OUTPUT"

# Extract report directory and run parser
REPORT_DIR=$(echo "$REPORT_OUTPUT" | grep "Report saved to:" | sed 's|Report saved to: ||' | xargs dirname)
if [[ -n "$REPORT_DIR" && -d "$REPORT_DIR" ]]; then
    echo ""
    echo "=== Running Report Parser ==="
    python3 "${PROJECT_ROOT}/scripts/report-parser.py" "$REPORT_DIR" | tee "${REPORT_DIR}/summary.txt"
    echo "Summary saved to: ${REPORT_DIR}/summary.txt"
fi

echo ""
echo "=== Report Generation Complete ==="
