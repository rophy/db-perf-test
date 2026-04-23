#!/bin/bash
set -euo pipefail

# Failure injection and recovery for fault tolerance testing.
#
# Usage: ft-inject.sh <action> <target> [options]
#   ft-inject.sh kill <target> [--mode pod-delete|vm-destroy]
#   ft-inject.sh recover <target>
#   ft-inject.sh status <target>
#
# Targets: yb-tserver-0, yb-tserver-1, yb-tserver-2, yb-master-0, etc.

KUBE_CONTEXT="${KUBE_CONTEXT:?KUBE_CONTEXT must be set}"
NAMESPACE="${NAMESPACE:?NAMESPACE must be set}"
FAILURE_MODE="${FAILURE_MODE:-pod-delete}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VM_DIR="$PROJECT_DIR/.vms"

ACTION="${1:?Usage: ft-inject.sh <kill|recover|status> <target>}"
TARGET="${2:?Usage: ft-inject.sh <kill|recover|status> <target>}"

# Resolve target pod to VM name
get_vm_for_pod() {
    local pod="$1"
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pod "$pod" \
        -o jsonpath='{.spec.nodeName}' 2>/dev/null
}

case "$ACTION" in
    kill)
        echo "=== Injecting failure: $TARGET (mode: $FAILURE_MODE) ==="

        if [ "$FAILURE_MODE" = "vm-destroy" ]; then
            vm_name=$(get_vm_for_pod "$TARGET")
            if [ -z "$vm_name" ]; then
                echo "ERROR: Cannot resolve VM for pod $TARGET" >&2
                exit 1
            fi
            echo "  Pod $TARGET runs on VM: $vm_name"
            echo "  Destroying VM (hard power off)..."
            virsh destroy "$vm_name" 2>/dev/null || true
            echo "  VM $vm_name destroyed"
        else
            echo "  Deleting pod $TARGET..."
            kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" delete pod "$TARGET" \
                --grace-period=0 --force 2>/dev/null || true
            echo "  Pod $TARGET deleted"
        fi

        echo "  Failure injected at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        ;;

    recover)
        echo "=== Recovering: $TARGET ==="

        if [ "$FAILURE_MODE" = "vm-destroy" ]; then
            vm_name=$(get_vm_for_pod "$TARGET" 2>/dev/null || true)
            # If pod can't be resolved (VM is down), try to guess VM name from target
            if [ -z "$vm_name" ]; then
                # Load VM IPs to find which VM hosted this pod previously
                if [ -f "$VM_DIR/vm-ips.env" ]; then
                    # Try to find VM by checking all workers
                    for vm in ygdb-worker-1 ygdb-worker-2 ygdb-worker-3; do
                        if ! virsh domstate "$vm" 2>/dev/null | grep -q "running"; then
                            vm_name="$vm"
                            echo "  Found stopped VM: $vm_name"
                            break
                        fi
                    done
                fi
            fi

            if [ -z "$vm_name" ]; then
                echo "ERROR: Cannot find stopped VM to recover" >&2
                exit 1
            fi

            echo "  Starting VM $vm_name..."
            virsh start "$vm_name" 2>/dev/null || true

            # Wait for VM to be running
            for attempt in $(seq 1 30); do
                if virsh domstate "$vm_name" 2>/dev/null | grep -q "running"; then
                    echo "  VM $vm_name running"
                    break
                fi
                sleep 2
            done
        else
            echo "  Pod $TARGET will be auto-recreated by StatefulSet controller"
        fi

        # Wait for pod to be ready
        echo "  Waiting for pod $TARGET to be Ready..."
        for attempt in $(seq 1 60); do
            phase=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pod "$TARGET" \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
            ready=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pod "$TARGET" \
                -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
            if [ "$phase" = "Running" ] && [ "$ready" = "true" ]; then
                echo "  Pod $TARGET is Ready"
                echo "  Recovered at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
                exit 0
            fi
            [ "$attempt" -eq 60 ] && { echo "ERROR: Pod $TARGET did not become Ready after 120s" >&2; exit 1; }
            sleep 2
        done
        ;;

    status)
        echo "=== Status: $TARGET ==="
        kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pod "$TARGET" -o wide 2>/dev/null || echo "  Pod not found"
        vm_name=$(get_vm_for_pod "$TARGET" 2>/dev/null || echo "unknown")
        if [ "$vm_name" != "unknown" ]; then
            echo "  VM: $vm_name ($(virsh domstate "$vm_name" 2>/dev/null || echo 'unknown'))"
        fi
        ;;

    *)
        echo "ERROR: Unknown action: $ACTION" >&2
        echo "Usage: ft-inject.sh <kill|recover|status> <target>" >&2
        exit 1
        ;;
esac
