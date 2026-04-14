#!/bin/bash
set -euo pipefail

VM_PREFIX="${VM_PREFIX:-ygdb}"
WORKER_COUNT="${WORKER_COUNT:-3}"
DISK_DELAY_MS="${DISK_DELAY_MS:?DISK_DELAY_MS required (e.g. 5, 10, 0 to disable)}"
DM_NAME="slow-disk0"
BACKING_FILE="/mnt/slow-disk-data/disk0.img"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/.vms"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

if [ ! -f "$VM_DIR/vm-ips.env" ]; then
    echo "ERROR: $VM_DIR/vm-ips.env not found. Run setup-k3s-virsh.sh first." >&2
    exit 1
fi
source "$VM_DIR/vm-ips.env"

# Live-adjust dm-delay latency on all worker VMs without reformatting the disk.
# Requires setup-slow-disk.sh to have been run first.
# Compare with setup-slow-disk.sh which recreates the backing file + mkfs (destructive).
echo "=== Adjusting dm-delay to ${DISK_DELAY_MS}ms (live, no data loss) ==="

for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"
    ip_var="WORKER_${i}_IP"
    ip="${!ip_var}"

    echo "Updating $vm ($ip)..."

    ssh $SSH_OPTS "ubuntu@${ip}" bash << REMOTE_SCRIPT
set -euo pipefail

if [ ! -e /dev/mapper/${DM_NAME} ]; then
    echo "  ERROR: /dev/mapper/${DM_NAME} not found. Run setup-slow-disk.sh first." >&2
    exit 1
fi

LOOP=\$(losetup -j ${BACKING_FILE} 2>/dev/null | cut -d: -f1 | head -1)
if [ -z "\$LOOP" ]; then
    echo "  ERROR: no loop device for ${BACKING_FILE}" >&2
    exit 1
fi

SECTORS=\$(sudo blockdev --getsz "\$LOOP")

sudo dmsetup suspend ${DM_NAME}
echo "0 \$SECTORS delay \$LOOP 0 ${DISK_DELAY_MS}" | sudo dmsetup reload ${DM_NAME}
sudo dmsetup resume ${DM_NAME}

echo "  New table: \$(sudo dmsetup table ${DM_NAME})"
REMOTE_SCRIPT

    echo "  $vm: done"
done

echo ""
echo "=== Delay adjustment complete (data preserved) ==="
