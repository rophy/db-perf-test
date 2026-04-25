#!/bin/bash
set -euo pipefail

VM_PREFIX="${VM_PREFIX:-ygvm}"
MASTER_COUNT="${MASTER_COUNT:-3}"
TSERVER_COUNT="${TSERVER_COUNT:-3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/.vms"

echo "=== Tearing down vm-virsh VMs ==="

ALL_VMS=""
for i in $(seq 1 "$MASTER_COUNT"); do
    ALL_VMS="$ALL_VMS ${VM_PREFIX}-master-${i}"
done
for i in $(seq 1 "$TSERVER_COUNT"); do
    ALL_VMS="$ALL_VMS ${VM_PREFIX}-tserver-${i}"
done

for vm in $ALL_VMS; do
    if virsh dominfo "$vm" &>/dev/null; then
        echo "  Destroying $vm..."
        virsh destroy "$vm" 2>/dev/null || true
        virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
        rm -f "$VM_DIR/${vm}-cidata.iso"
        echo "  $vm: removed"
    else
        echo "  $vm: not found, skipping"
    fi
done

# Clean up generated files (keep base cloud image)
rm -f "$VM_DIR/vm-ips.env"
rm -f "$PROJECT_DIR/ansible/inventory/vm-virsh.ini"

# Tear down kind cluster used for bench tools
echo ""
echo "Deleting kind cluster..."
kind delete cluster --name kind 2>/dev/null || true

echo ""
echo "=== Teardown Complete ==="
echo "Note: Base cloud image preserved at $VM_DIR/"
