#!/bin/bash
set -euo pipefail

# HammerDB entrypoint script
# Commands: build, run, delete, shell, web, sleep

COMMAND="${1:-sleep}"
HAMMERDB_HOME="${HAMMERDB_HOME:-/home/hammerdb}"

case "$COMMAND" in
    build)
        echo "=== Building TPROC-C Schema ==="
        cd "$HAMMERDB_HOME"
        ./hammerdbcli auto /scripts/buildschema.tcl
        ;;
    run)
        echo "=== Running TPROC-C Workload ==="
        cd "$HAMMERDB_HOME"
        ./hammerdbcli auto /scripts/runworkload.tcl
        ;;
    delete)
        echo "=== Deleting TPROC-C Schema ==="
        cd "$HAMMERDB_HOME"
        ./hammerdbcli auto /scripts/deleteschema.tcl
        ;;
    shell)
        echo "=== Starting HammerDB CLI Shell ==="
        cd "$HAMMERDB_HOME"
        exec ./hammerdbcli
        ;;
    web)
        echo "=== Starting HammerDB Web Service ==="
        cd "$HAMMERDB_HOME"
        exec ./hammerdbws
        ;;
    sleep)
        echo "=== HammerDB container ready ==="
        echo "Use 'kubectl exec' to run commands:"
        echo "  kubectl exec -it <pod> -- /scripts/entrypoint.sh build"
        echo "  kubectl exec -it <pod> -- /scripts/entrypoint.sh run"
        echo "  kubectl exec -it <pod> -- /scripts/entrypoint.sh delete"
        echo "  kubectl exec -it <pod> -- /scripts/entrypoint.sh shell"
        exec sleep infinity
        ;;
    *)
        echo "Unknown command: $COMMAND"
        echo "Usage: entrypoint.sh [build|run|delete|shell|web|sleep]"
        exit 1
        ;;
esac
