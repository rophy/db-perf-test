#!/bin/bash
set -e

# VM-hybrid k6 benchmark runner.
# YugabyteDB runs on bare-metal VMs, k6 runs in a kind cluster.
# Collects VM specs via virsh, then delegates to the k8s runner.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VM_DIR="${PROJECT_ROOT}/.vms"
VM_IPS="${VM_DIR}/vm-ips.env"

if [ ! -f "$VM_IPS" ]; then
    echo "ERROR: ${VM_IPS} not found. Run: make setup-vm-virsh" >&2
    exit 1
fi

source "$VM_IPS"

OUTPUT_DIR="${PROJECT_ROOT}/output"
mkdir -p "$OUTPUT_DIR"

# Collect tserver VM specs via virsh (not kubectl — tservers are bare-metal)
echo "Collecting VM specs..."
echo -e "pod_name\tnode_name\tcpu\tmemory" > "${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
for var in $(grep "^TSERVER_.*_IP=" "$VM_IPS" | sort); do
    name=$(echo "$var" | cut -d= -f1 | sed 's/_IP$//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    vcpus=$(virsh dominfo "ygvm-${name}" 2>/dev/null | grep "CPU(s):" | awk '{print $2}')
    mem_kb=$(virsh dominfo "ygvm-${name}" 2>/dev/null | grep "Max memory:" | awk '{print $3}')
    mem_mi="$((mem_kb / 1024))Mi"
    echo -e "ygvm-${name}\tygvm-${name}\t${vcpus}\t${mem_mi}" >> "${OUTPUT_DIR}/RUN_NODE_SPEC.txt"
done
echo "VM specs saved."
echo ""

# Delegate to the standard k8s runner (k6 runs in kind)
export KUBE_CONTEXT="${KUBE_CONTEXT:-kind-kind}"
export NAMESPACE="${NAMESPACE:-yugabyte-test}"
export RELEASE_NAME="${RELEASE_NAME:-yb-benchmark}"
export K6_SCRIPT="${K6_SCRIPT:-test.js}"

exec "${SCRIPT_DIR}/k6-run-with-timestamps.sh"
