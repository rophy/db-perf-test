#!/bin/bash
set -euo pipefail

# Configuration
VM_PREFIX="${VM_PREFIX:-ygvm}"
CONTROL_CPUS="${CONTROL_CPUS:-2}"
CONTROL_MEMORY="${CONTROL_MEMORY:-4096}"
CONTROL_CPU_PINNING="${CONTROL_CPU_PINNING:-}"
TSERVER_COUNT="${TSERVER_COUNT:-3}"
TSERVER_CPUS="${TSERVER_CPUS:-2}"
TSERVER_MEMORY="${TSERVER_MEMORY:-8192}"
TSERVER_CPU_PINNING="${TSERVER_CPU_PINNING:-}"
DISK_SIZE="${DISK_SIZE:-20G}"
DISK_FORMAT="${DISK_FORMAT:-qcow2}"
DISK_CACHE="${DISK_CACHE:-none}"
DISK_IO="${DISK_IO:-native}"
NETWORK="${NETWORK:-default}"
OS_VARIANT="${OS_VARIANT:-ubuntu22.04}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/.vms"
CLOUD_IMG="$VM_DIR/ubuntu-22.04-cloudimg.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
VM_BASE_IMG="${VM_BASE_IMG:-$CLOUD_IMG}"

SSH_KEY=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

echo "=== YugabyteDB VM Setup (virsh, no k8s) ==="
echo "VMs: 1 control ($CONTROL_CPUS CPU / ${CONTROL_MEMORY}MB) + $TSERVER_COUNT tservers ($TSERVER_CPUS CPU / ${TSERVER_MEMORY}MB)"
echo "Base image: $VM_BASE_IMG"
if [ -n "$CONTROL_CPU_PINNING" ]; then
    echo "Control CPU pinning: $CONTROL_CPU_PINNING"
fi
if [ -n "$TSERVER_CPU_PINNING" ]; then
    echo "Tserver CPU pinning: $TSERVER_CPU_PINNING"
fi
echo ""

# --- Prerequisites ---
echo "Checking prerequisites..."
for cmd in virsh virt-install qemu-img genisoimage; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required but not installed." >&2; exit 1; }
done

if [ -z "$SSH_KEY" ]; then
    echo "ERROR: No SSH public key found (~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)" >&2
    exit 1
fi

# --- Base image ---
mkdir -p "$VM_DIR"
if [ ! -f "$VM_BASE_IMG" ]; then
    if [ "$VM_BASE_IMG" = "$CLOUD_IMG" ]; then
        echo "Downloading Ubuntu 22.04 cloud image..."
        wget -q --show-progress -O "$CLOUD_IMG" "$CLOUD_IMG_URL"
    else
        echo "ERROR: Base image not found: $VM_BASE_IMG" >&2
        exit 1
    fi
fi

# --- VM creation ---
create_vm() {
    local name="$1"
    local cpus="$2"
    local memory="$3"
    local cpuset="${4:-}"

    if virsh domstate "$name" 2>/dev/null | grep -q "running"; then
        echo "  $name: already running, skipping"
        return 0
    fi

    if virsh dominfo "$name" &>/dev/null; then
        echo "  $name: exists but not running, recreating..."
        virsh destroy "$name" 2>/dev/null || true
        virsh undefine "$name" --remove-all-storage 2>/dev/null || true
    fi

    echo "  $name: creating VM ($cpus CPU, ${memory}MB RAM, $DISK_SIZE disk)..."

    # Create disk from base image
    local src_format disk_file
    src_format=$(qemu-img info --output=json "$VM_BASE_IMG" | python3 -c "import sys,json; print(json.load(sys.stdin)['format'])")
    disk_file="$VM_DIR/${name}.${DISK_FORMAT}"
    qemu-img convert -f "$src_format" -O "$DISK_FORMAT" "$VM_BASE_IMG" "$disk_file"
    if [ "$DISK_FORMAT" = "raw" ]; then
        truncate -s "$DISK_SIZE" "$disk_file"
    else
        qemu-img resize "$disk_file" "$DISK_SIZE"
    fi

    # Generate cloud-init
    mkdir -p "/tmp/cloud-init-${name}"

    cat > "/tmp/cloud-init-${name}/user-data" << EOF
#cloud-config
hostname: ${name}
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_KEY}
EOF

    cat > "/tmp/cloud-init-${name}/meta-data" << EOF
instance-id: ${name}
local-hostname: ${name}
EOF

    cat > "/tmp/cloud-init-${name}/network-config" << EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: true
EOF

    genisoimage -output "$VM_DIR/${name}-cidata.iso" \
        -volid cidata -joliet -rock -input-charset utf-8 \
        "/tmp/cloud-init-${name}/user-data" "/tmp/cloud-init-${name}/meta-data" \
        "/tmp/cloud-init-${name}/network-config" \
        >/dev/null 2>&1

    rm -rf "/tmp/cloud-init-${name}"

    local cpuset_flag=""
    if [ -n "$cpuset" ]; then
        cpuset_flag="--cpuset=$cpuset"
    fi

    virt-install \
        --name "$name" \
        --memory "$memory" \
        --vcpus "$cpus" \
        $cpuset_flag \
        --disk "path=${disk_file},format=${DISK_FORMAT},cache=${DISK_CACHE},io=${DISK_IO}" \
        --disk "path=$VM_DIR/${name}-cidata.iso,device=cdrom" \
        --os-variant "$OS_VARIANT" \
        --network "network=$NETWORK" \
        --graphics none \
        --noautoconsole \
        --import \
        >/dev/null 2>&1

    echo "  $name: VM created"
}

echo ""
echo "Creating VMs..."

# Parse tserver CPU pinning into array
IFS=' ' read -ra TSERVER_PIN_ARRAY <<< "$TSERVER_CPU_PINNING"

create_vm "${VM_PREFIX}-control" "$CONTROL_CPUS" "$CONTROL_MEMORY" "$CONTROL_CPU_PINNING"
for i in $(seq 1 "$TSERVER_COUNT"); do
    tserver_cpuset="${TSERVER_PIN_ARRAY[$((i-1))]:-}"
    if [ -n "$tserver_cpuset" ]; then
        echo "  (pinning tserver-${i} to CPUs: $tserver_cpuset)"
    fi
    create_vm "${VM_PREFIX}-tserver-${i}" "$TSERVER_CPUS" "$TSERVER_MEMORY" "$tserver_cpuset"
done

# --- Wait for IPs ---
get_vm_ip() {
    local name="$1"
    virsh domifaddr "$name" 2>/dev/null | grep ipv4 | awk '{print $4}' | cut -d/ -f1 || true
}

echo ""
echo "Waiting for VMs to get IP addresses..."
ALL_VMS="${VM_PREFIX}-control"
for i in $(seq 1 "$TSERVER_COUNT"); do
    ALL_VMS="$ALL_VMS ${VM_PREFIX}-tserver-${i}"
done

declare -A VM_IPS
for vm in $ALL_VMS; do
    for attempt in $(seq 1 30); do
        ip=$(get_vm_ip "$vm")
        if [ -n "$ip" ]; then
            VM_IPS[$vm]="$ip"
            echo "  $vm: $ip"
            break
        fi
        [ "$attempt" -eq 30 ] && { echo "ERROR: $vm did not get an IP after 30 attempts" >&2; exit 1; }
        sleep 2
    done
done

CONTROL_IP="${VM_IPS[${VM_PREFIX}-control]}"

# --- Wait for SSH ---
echo ""
echo "Waiting for SSH access..."
for vm in $ALL_VMS; do
    ip="${VM_IPS[$vm]}"
    for attempt in $(seq 1 30); do
        if ssh $SSH_OPTS "ubuntu@${ip}" "true" 2>/dev/null; then
            echo "  $vm ($ip): SSH OK"
            break
        fi
        [ "$attempt" -eq 30 ] && { echo "ERROR: SSH to $vm ($ip) failed after 30 attempts" >&2; exit 1; }
        sleep 5
    done
done

# --- Wait for cloud-init to finish ---
echo ""
echo "Waiting for cloud-init to complete..."
for vm in $ALL_VMS; do
    ip="${VM_IPS[$vm]}"
    ssh $SSH_OPTS "ubuntu@${ip}" "cloud-init status --wait" >/dev/null 2>&1
    echo "  $vm: cloud-init done"
done

# --- Save VM IP mapping ---
cat > "$VM_DIR/vm-ips.env" << EOF
# Auto-generated by setup-vm-virsh.sh
CONTROL_IP=${CONTROL_IP}
EOF
for i in $(seq 1 "$TSERVER_COUNT"); do
    vm="${VM_PREFIX}-tserver-${i}"
    echo "TSERVER_${i}_IP=${VM_IPS[$vm]}" >> "$VM_DIR/vm-ips.env"
done

# --- Generate Ansible inventory ---
INVENTORY_DIR="$PROJECT_DIR/ansible/inventory"
mkdir -p "$INVENTORY_DIR"
cat > "$INVENTORY_DIR/vm-virsh.ini" << EOF
# Auto-generated by setup-vm-virsh.sh
[control]
${VM_PREFIX}-control ansible_host=${CONTROL_IP}

[yb_tservers]
EOF
for i in $(seq 1 "$TSERVER_COUNT"); do
    vm="${VM_PREFIX}-tserver-${i}"
    echo "${vm} ansible_host=${VM_IPS[$vm]}" >> "$INVENTORY_DIR/vm-virsh.ini"
done
cat >> "$INVENTORY_DIR/vm-virsh.ini" << 'EOF'

[yb:children]
control
yb_tservers

[all:vars]
ansible_user=ubuntu
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
EOF

echo ""
echo "=== VM IPs ==="
cat "$VM_DIR/vm-ips.env"
echo ""
echo "=== Ansible Inventory ==="
cat "$INVENTORY_DIR/vm-virsh.ini"
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Deploy YB + bench:  make deploy ENV=vm-virsh"
echo "  2. Check status:       make status ENV=vm-virsh"
echo "  3. Run benchmark:      make k6-run ENV=vm-virsh"
