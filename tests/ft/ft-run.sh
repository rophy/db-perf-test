#!/bin/bash
set -euo pipefail

# Fault tolerance test orchestrator.
# Runs a complete test: write → inject failure → wait → recover → verify
#
# Usage: ft-run.sh --scenario <name> --target <pod> [options]
#
# Examples:
#   ft-run.sh --scenario 1-tserver-down --target yb-tserver-0
#   ft-run.sh --scenario 1-tserver-down --target yb-tserver-1 --failure-mode vm-destroy --duration 60
#   ft-run.sh --scenario 2-tserver-down --target "yb-tserver-0 yb-tserver-1"
#   ft-run.sh --scenario 1-master-down --target yb-master-0

KUBE_CONTEXT="${KUBE_CONTEXT:?KUBE_CONTEXT must be set}"
NAMESPACE="${NAMESPACE:?NAMESPACE must be set}"
FAILURE_MODE="${FAILURE_MODE:-pod-delete}"
FAILURE_DURATION="${FAILURE_DURATION:-30}"
BASELINE_DURATION="${BASELINE_DURATION:-10}"
RECOVERY_WAIT="${RECOVERY_WAIT:-30}"
INSERT_INTERVAL_MS="${INSERT_INTERVAL_MS:-100}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
SCENARIO=""
TARGETS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario) SCENARIO="$2"; shift 2 ;;
        --target) TARGETS="$2"; shift 2 ;;
        --failure-mode) FAILURE_MODE="$2"; shift 2 ;;
        --duration) FAILURE_DURATION="$2"; shift 2 ;;
        --baseline) BASELINE_DURATION="$2"; shift 2 ;;
        --recovery-wait) RECOVERY_WAIT="$2"; shift 2 ;;
        --interval) INSERT_INTERVAL_MS="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$SCENARIO" ] || [ -z "$TARGETS" ]; then
    echo "Usage: ft-run.sh --scenario <name> --target <pod> [options]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --failure-mode    pod-delete or vm-destroy (default: pod-delete)" >&2
    echo "  --duration        failure duration in seconds (default: 30)" >&2
    echo "  --baseline        baseline write duration before failure (default: 10)" >&2
    echo "  --recovery-wait   wait time after recovery (default: 30)" >&2
    echo "  --interval        insert interval in ms (default: 100)" >&2
    exit 1
fi

# Setup report directory
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
REPORT_DIR="$SCRIPT_DIR/reports/${SCENARIO}_${TIMESTAMP}"
mkdir -p "$REPORT_DIR"
JOURNAL_FILE="$REPORT_DIR/writer-journal.csv"

echo "============================================"
echo "  Fault Tolerance Test: $SCENARIO"
echo "============================================"
echo "Target(s): $TARGETS"
echo "Failure mode: $FAILURE_MODE"
echo "Baseline: ${BASELINE_DURATION}s"
echo "Failure duration: ${FAILURE_DURATION}s"
echo "Recovery wait: ${RECOVERY_WAIT}s"
echo "Insert interval: ${INSERT_INTERVAL_MS}ms"
echo "Report dir: $REPORT_DIR"
echo ""

# Save test config
cat > "$REPORT_DIR/test-config.txt" << EOF
scenario: $SCENARIO
targets: $TARGETS
failure_mode: $FAILURE_MODE
baseline_duration: $BASELINE_DURATION
failure_duration: $FAILURE_DURATION
recovery_wait: $RECOVERY_WAIT
insert_interval_ms: $INSERT_INTERVAL_MS
start_time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
kube_context: $KUBE_CONTEXT
namespace: $NAMESPACE
EOF

# --- Step 1: Pre-flight check ---
echo "=== Step 1: Pre-flight Check ==="
echo "  Checking cluster health..."
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods -l 'app in (yb-master,yb-tserver)' --no-headers | \
    while read -r line; do echo "  $line"; done
echo ""

# --- Step 2: Start writer ---
echo "=== Step 2: Start Writer ==="
export KUBE_CONTEXT NAMESPACE INSERT_INTERVAL_MS
bash "$SCRIPT_DIR/ft-writer.sh" "$JOURNAL_FILE" &
WRITER_PID=$!
echo "  Writer PID: $WRITER_PID"
echo ""

# --- Step 3: Baseline writes ---
echo "=== Step 3: Baseline Writes (${BASELINE_DURATION}s) ==="
sleep "$BASELINE_DURATION"
baseline_count=$(tail -n +2 "$JOURNAL_FILE" | grep -c ',OK$' || true)
echo "  Baseline inserts: $baseline_count"
echo "baseline_inserts: $baseline_count" >> "$REPORT_DIR/test-config.txt"
echo ""

# --- Step 4: Inject failure ---
echo "=== Step 4: Inject Failure ==="
failure_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "failure_inject_time: $failure_time" >> "$REPORT_DIR/test-config.txt"

for target in $TARGETS; do
    FAILURE_MODE="$FAILURE_MODE" bash "$SCRIPT_DIR/ft-inject.sh" kill "$target"
done
echo ""

# --- Step 5: Wait during failure ---
echo "=== Step 5: Writes During Failure (${FAILURE_DURATION}s) ==="
sleep "$FAILURE_DURATION"
during_count=$(tail -n +2 "$JOURNAL_FILE" | wc -l)
echo "  Total inserts so far: $during_count"
echo ""

# --- Step 6: Recover ---
echo "=== Step 6: Recover ==="
recovery_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "recovery_start_time: $recovery_time" >> "$REPORT_DIR/test-config.txt"

for target in $TARGETS; do
    FAILURE_MODE="$FAILURE_MODE" bash "$SCRIPT_DIR/ft-inject.sh" recover "$target"
done
echo ""

# --- Step 7: Wait for recovery ---
echo "=== Step 7: Recovery Stabilization (${RECOVERY_WAIT}s) ==="
sleep "$RECOVERY_WAIT"
echo ""

# --- Step 8: Stop writer ---
echo "=== Step 8: Stop Writer ==="
kill "$WRITER_PID" 2>/dev/null || true
wait "$WRITER_PID" 2>/dev/null || true
total_inserts=$(tail -n +2 "$JOURNAL_FILE" | wc -l)
echo "  Total insert attempts: $total_inserts"
echo "total_inserts: $total_inserts" >> "$REPORT_DIR/test-config.txt"
echo ""

# --- Step 9: Verify ---
echo "=== Step 9: Verify Data Consistency ==="
echo ""
bash "$SCRIPT_DIR/ft-verify.sh" "$JOURNAL_FILE" "$REPORT_DIR"
verify_exit=$?
echo ""

# --- Final status ---
echo "end_time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$REPORT_DIR/test-config.txt"
echo "result: $([ $verify_exit -eq 0 ] && echo 'PASS' || echo 'FAIL')" >> "$REPORT_DIR/test-config.txt"

echo "============================================"
if [ $verify_exit -eq 0 ]; then
    echo "  TEST PASSED: $SCENARIO"
else
    echo "  TEST FAILED: $SCENARIO"
fi
echo "  Report: $REPORT_DIR"
echo "============================================"

exit $verify_exit
