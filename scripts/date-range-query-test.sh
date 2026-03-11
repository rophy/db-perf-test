#!/bin/bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
KUBECTL="kubectl --context $KUBE_CONTEXT -n $NAMESPACE"

TABLE="${TABLE:-date_range_test}"
TABLE_SIZE="${TABLE_SIZE:-100000}"
ITERATIONS="${ITERATIONS:-1}"
INTERVALS="${INTERVALS:-1 7 30 90 180}"
QUERY_TYPES="${QUERY_TYPES:-select count}"
CLIENT="${CLIENT:-ysqlsh}"

DATE_START="2025-01-01"

SYSBENCH_POD="deployment/yb-bench-sysbench"

echo "=== Date Range Query Performance Test ==="
echo ""
echo "Table: $TABLE (${TABLE_SIZE} rows)"
echo "Iterations per interval: $ITERATIONS"
echo "Intervals (days): $INTERVALS"
echo "Query types: $QUERY_TYPES"
echo "Client: $CLIENT"
echo ""

run_query() {
    local label=$1
    local sql=$2
    local start_ns end_ns elapsed_ms
    local tmpfile
    tmpfile=$(mktemp)
    start_ns=$(date +%s%N)
    case "$CLIENT" in
        ysqlsh)
            $KUBECTL exec yb-tserver-0 -- /home/yugabyte/bin/ysqlsh \
                -h yb-tserver-service -t -A -c "$sql" 2>/dev/null > "$tmpfile"
            ;;
        psql)
            $KUBECTL exec $SYSBENCH_POD -- psql \
                -h yb-tserver-service -p 5433 -U yugabyte -d yugabyte \
                -t -A -c "$sql" 2>/dev/null > "$tmpfile"
            ;;
        *)
            echo "Unknown client: $CLIENT" >&2; rm -f "$tmpfile"; exit 1
            ;;
    esac
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local rows
    rows=$(wc -l < "$tmpfile")
    rm -f "$tmpfile"
    printf "%-30s %6d ms  rows: %s\n" "$label" "$elapsed_ms" "$rows"
}

for QUERY_TYPE in $QUERY_TYPES; do
    for INTERVAL_DAYS in $INTERVALS; do
        for i in $(seq 1 $ITERATIONS); do
            MAX_START_OFFSET=$((365 - INTERVAL_DAYS))
            if [ "$MAX_START_OFFSET" -lt 1 ]; then MAX_START_OFFSET=1; fi
            OFFSET=$((RANDOM % MAX_START_OFFSET))
            END_OFFSET=$((OFFSET + INTERVAL_DAYS))

            case "$QUERY_TYPE" in
                select)
                    SQL="SELECT * FROM $TABLE WHERE created_at >= '${DATE_START}'::timestamp + interval '${OFFSET} days' AND created_at < '${DATE_START}'::timestamp + interval '${END_OFFSET} days'"
                    ;;
                count)
                    SQL="SELECT COUNT(*) FROM $TABLE WHERE created_at >= '${DATE_START}'::timestamp + interval '${OFFSET} days' AND created_at < '${DATE_START}'::timestamp + interval '${END_OFFSET} days'"
                    ;;
                *)
                    echo "Unknown query type: $QUERY_TYPE" >&2; exit 1
                    ;;
            esac

            LABEL="${QUERY_TYPE} interval=${INTERVAL_DAYS}d"
            if [ "$ITERATIONS" -gt 1 ]; then
                LABEL="${LABEL} #${i}"
            fi
            run_query "$LABEL" "$SQL"
        done
    done
done

echo ""
echo "=== Test Complete ==="
