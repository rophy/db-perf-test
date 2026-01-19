#!/bin/bash
set -e

# Sysbench entrypoint script for YugabyteDB benchmarking
# Follows similar pattern to HammerDB entrypoint

# Database connection settings (with defaults for YugabyteDB)
: "${PG_HOST:=yb-tserver-service}"
: "${PG_PORT:=5433}"
: "${PG_USER:=yugabyte}"
: "${PG_PASS:=yugabyte}"
: "${PG_DB:=yugabyte}"

# Sysbench settings (minimal defaults for development)
: "${SYSBENCH_TABLES:=1}"
: "${SYSBENCH_TABLE_SIZE:=1000}"
: "${SYSBENCH_THREADS:=1}"
: "${SYSBENCH_TIME:=60}"
: "${SYSBENCH_WARMUP:=10}"
: "${SYSBENCH_WORKLOAD:=oltp_read_write}"

# YugabyteDB-specific settings (from docs)
: "${SYSBENCH_RANGE_KEY_PARTITIONING:=false}"
: "${SYSBENCH_SERIAL_CACHE_SIZE:=1000}"
: "${SYSBENCH_CREATE_SECONDARY:=true}"

# Build common sysbench options
# Note: YugabyteDB-specific options (range_key_partitioning, serial_cache_size, create_secondary)
# are only available in the YugabyteDB fork of sysbench. Standard sysbench doesn't support them.
build_common_opts() {
    echo "--db-driver=pgsql \
--pgsql-host=${PG_HOST} \
--pgsql-port=${PG_PORT} \
--pgsql-user=${PG_USER} \
--pgsql-password=${PG_PASS} \
--pgsql-db=${PG_DB} \
--tables=${SYSBENCH_TABLES} \
--table_size=${SYSBENCH_TABLE_SIZE}"
}

# Prepare: Create tables and load data
do_prepare() {
    echo "=== Sysbench Prepare Phase ==="
    echo "Host: ${PG_HOST}:${PG_PORT}"
    echo "Database: ${PG_DB}"
    echo "Tables: ${SYSBENCH_TABLES}, Size: ${SYSBENCH_TABLE_SIZE}"
    echo ""

    local opts=$(build_common_opts)
    echo "Running: sysbench ${SYSBENCH_WORKLOAD} ${opts} prepare"
    echo ""

    sysbench ${SYSBENCH_WORKLOAD} ${opts} prepare

    echo ""
    echo "=== Prepare Complete ==="
}

# Run: Execute the benchmark
do_run() {
    echo "=== Sysbench Run Phase ==="
    echo "Host: ${PG_HOST}:${PG_PORT}"
    echo "Database: ${PG_DB}"
    echo "Workload: ${SYSBENCH_WORKLOAD}"
    echo "Threads: ${SYSBENCH_THREADS}"
    echo "Duration: ${SYSBENCH_TIME}s (warmup: ${SYSBENCH_WARMUP}s)"
    echo ""

    local opts=$(build_common_opts)
    opts="${opts} \
--threads=${SYSBENCH_THREADS} \
--time=${SYSBENCH_TIME} \
--report-interval=10"

    echo "Running: sysbench ${SYSBENCH_WORKLOAD} ${opts} run"
    echo ""

    sysbench ${SYSBENCH_WORKLOAD} ${opts} run

    echo ""
    echo "=== Run Complete ==="
}

# Cleanup: Drop tables
do_cleanup() {
    echo "=== Sysbench Cleanup Phase ==="
    echo "Host: ${PG_HOST}:${PG_PORT}"
    echo "Database: ${PG_DB}"
    echo ""

    local opts=$(build_common_opts)
    echo "Running: sysbench ${SYSBENCH_WORKLOAD} ${opts} cleanup"
    echo ""

    sysbench ${SYSBENCH_WORKLOAD} ${opts} cleanup

    echo ""
    echo "=== Cleanup Complete ==="
}

# Show current configuration
do_config() {
    echo "=== Sysbench Configuration ==="
    echo ""
    echo "Database Connection:"
    echo "  PG_HOST=${PG_HOST}"
    echo "  PG_PORT=${PG_PORT}"
    echo "  PG_USER=${PG_USER}"
    echo "  PG_DB=${PG_DB}"
    echo ""
    echo "Benchmark Settings:"
    echo "  SYSBENCH_WORKLOAD=${SYSBENCH_WORKLOAD}"
    echo "  SYSBENCH_TABLES=${SYSBENCH_TABLES}"
    echo "  SYSBENCH_TABLE_SIZE=${SYSBENCH_TABLE_SIZE}"
    echo "  SYSBENCH_THREADS=${SYSBENCH_THREADS}"
    echo "  SYSBENCH_TIME=${SYSBENCH_TIME}"
    echo "  SYSBENCH_WARMUP=${SYSBENCH_WARMUP}"
    echo ""
    echo "YugabyteDB Settings:"
    echo "  SYSBENCH_RANGE_KEY_PARTITIONING=${SYSBENCH_RANGE_KEY_PARTITIONING}"
    echo "  SYSBENCH_SERIAL_CACHE_SIZE=${SYSBENCH_SERIAL_CACHE_SIZE}"
    echo "  SYSBENCH_CREATE_SECONDARY=${SYSBENCH_CREATE_SECONDARY}"
    echo ""
    echo "Available Workloads:"
    echo "  oltp_read_only"
    echo "  oltp_read_write"
    echo "  oltp_write_only"
    echo "  oltp_update_index"
    echo "  oltp_update_non_index"
    echo "  oltp_insert"
    echo "  oltp_delete"
}

# Main command dispatcher
case "${1:-sleep}" in
    prepare)
        do_prepare
        ;;
    run)
        do_run
        ;;
    cleanup)
        do_cleanup
        ;;
    config)
        do_config
        ;;
    shell)
        exec /bin/bash
        ;;
    sleep)
        echo "Sysbench container ready. Use kubectl exec to run commands."
        do_config
        exec sleep infinity
        ;;
    *)
        echo "Usage: $0 {prepare|run|cleanup|config|shell|sleep}"
        echo ""
        echo "Commands:"
        echo "  prepare  - Create tables and load test data"
        echo "  run      - Execute the benchmark workload"
        echo "  cleanup  - Drop benchmark tables"
        echo "  config   - Show current configuration"
        echo "  shell    - Start interactive bash shell"
        echo "  sleep    - Keep container running (default)"
        exit 1
        ;;
esac
