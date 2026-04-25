#!/bin/bash
set -e

# VM-based k6 benchmark runner.
# Runs k6 on the control VM via SSH, records timestamps for the report pipeline.
# Output format matches k6-run-with-timestamps.sh so reports work for both.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VM_DIR="${PROJECT_ROOT}/.vms"
VM_IPS="${VM_DIR}/vm-ips.env"

if [ ! -f "$VM_IPS" ]; then
    echo "ERROR: ${VM_IPS} not found. Run: make setup-vm-virsh" >&2
    exit 1
fi

source "$VM_IPS"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_CONTROL="ssh ${SSH_OPTS} ubuntu@${CONTROL_IP}"

OUTPUT_DIR="${PROJECT_ROOT}/output"
mkdir -p "$OUTPUT_DIR"

echo "=== k6 Benchmark Runner (vm-virsh) ==="
echo "Control VM: ${CONTROL_IP}"
echo ""

# Collect tserver VM specs
echo "Collecting VM specs..."
echo -e "pod_name\tnode_name\tcpu\tmemory" > "${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
for var in $(grep "^TSERVER_.*_IP=" "$VM_IPS"); do
    name=$(echo "$var" | cut -d= -f1 | sed 's/_IP$//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    ip=$(echo "$var" | cut -d= -f2)
    vcpus=$(virsh dominfo "ygvm-${name}" 2>/dev/null | grep "CPU(s):" | awk '{print $2}')
    mem_kb=$(virsh dominfo "ygvm-${name}" 2>/dev/null | grep "Max memory:" | awk '{print $3}')
    mem_mi="$((mem_kb / 1024))Mi"
    echo -e "ygvm-${name}\tygvm-${name}\t${vcpus}\t${mem_mi}" >> "${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
done

echo -e "pod_name\tnode_name" > "${OUTPUT_DIR}/CLIENT_NODE_SPEC.txt"
echo -e "ygvm-control\tygvm-control" >> "${OUTPUT_DIR}/CLIENT_NODE_SPEC.txt"
echo "VM specs saved."
echo ""

# Read warmup time from env.sh on the control VM
WARMUP_TIME=$($SSH_CONTROL "grep BENCH_WARMUP /opt/bench/k6/env.sh | cut -d'\"' -f2" 2>/dev/null)
WARMUP_TIME="${WARMUP_TIME:-0}"

# Record start time
START_TIME=$(date +%s)
WARMUP_END_TIME=$(( START_TIME + WARMUP_TIME ))
TIMES_FILE="${OUTPUT_DIR}/test_times.txt"
{
    echo "WORKLOAD_TYPE=k6"
    echo "RUN_START_TIME=${START_TIME}"
    echo "WARMUP_END_TIME=${WARMUP_END_TIME}"
    echo "NUM_K6_PODS=1"
} > "$TIMES_FILE"
echo "Start time:       $(date -d @${START_TIME} '+%Y-%m-%d %H:%M:%S')"
echo "Warmup ends at:   $(date -d @${WARMUP_END_TIME} '+%Y-%m-%d %H:%M:%S') (warmup=${WARMUP_TIME}s)"
echo ""

# Run k6 on control VM
outfile="${OUTPUT_DIR}/k6_output_0.txt"
echo "Launching k6 on control VM..."
$SSH_CONTROL "source /opt/bench/k6/env.sh && /opt/bin/k6 run --out experimental-prometheus-rw /opt/bench/k6/test.js" 2>&1 | tee "${outfile}"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "ERROR: k6 failed" >&2
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
echo "Run 'make report ENV=vm-virsh' to generate the performance report."
