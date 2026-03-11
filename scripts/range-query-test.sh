#!/bin/bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
KUBECTL="kubectl --context $KUBE_CONTEXT -n $NAMESPACE"

TABLE="${TABLE:-sbtest1}"
TABLE_SIZE="${TABLE_SIZE:-100000}"
ITERATIONS="${ITERATIONS:-50}"
RANGE_SIZES="${RANGE_SIZES:-1 10 100 1000 10000}"
QUERY_TYPES="${QUERY_TYPES:-select count}"

echo "=== PK Range Query Performance Test ==="
echo ""
echo "Table: $TABLE (${TABLE_SIZE} rows)"
echo "Iterations per range size: $ITERATIONS"
echo "Range sizes: $RANGE_SIZES"
echo "Query types: $QUERY_TYPES"
echo ""

# Build SQL script
SQL_FILE=$(mktemp)
trap "rm -f $SQL_FILE" EXIT

echo "\\timing on" > "$SQL_FILE"

for QUERY_TYPE in $QUERY_TYPES; do
    for RANGE_SIZE in $RANGE_SIZES; do
        MAX_START=$((TABLE_SIZE - RANGE_SIZE))
        echo "\\echo === TYPE=${QUERY_TYPE} RANGE_SIZE=${RANGE_SIZE} ===" >> "$SQL_FILE"
        for i in $(seq 1 $ITERATIONS); do
            START_ID=$((RANDOM % MAX_START + 1))
            END_ID=$((START_ID + RANGE_SIZE - 1))
            case "$QUERY_TYPE" in
                select)
                    echo "SELECT * FROM $TABLE WHERE id BETWEEN $START_ID AND $END_ID;" >> "$SQL_FILE"
                    ;;
                count)
                    echo "SELECT COUNT(*) FROM $TABLE WHERE id BETWEEN $START_ID AND $END_ID;" >> "$SQL_FILE"
                    ;;
                *)
                    echo "Unknown query type: $QUERY_TYPE" >&2
                    exit 1
                    ;;
            esac
        done
    done
done

# Copy SQL to pod and run
$KUBECTL cp "$SQL_FILE" yb-tserver-0:/tmp/range-test.sql 2>/dev/null
echo "Running queries..."
OUTPUT=$($KUBECTL exec yb-tserver-0 -- /home/yugabyte/bin/ysqlsh \
    -h yb-tserver-service -f /tmp/range-test.sql 2>/dev/null)

echo ""

# Parse results
CURRENT_LABEL=""
TIMES=()

parse_and_print() {
    local label=$1
    shift
    local times=("$@")
    local count=${#times[@]}
    if [ "$count" -eq 0 ]; then return; fi

    local total=0 min=999999999 max=0
    for t in "${times[@]}"; do
        us=$(echo "$t" | awk '{printf "%d", $1 * 1000}')
        total=$((total + us))
        if [ "$us" -lt "$min" ]; then min=$us; fi
        if [ "$us" -gt "$max" ]; then max=$us; fi
    done
    local avg=$((total / count))

    printf "%-20s  Avg: %8.2f ms  Min: %8.2f ms  Max: %8.2f ms  (n=%d)\n" \
        "$label" \
        "$(echo "$avg" | awk '{printf "%.2f", $1/1000}')" \
        "$(echo "$min" | awk '{printf "%.2f", $1/1000}')" \
        "$(echo "$max" | awk '{printf "%.2f", $1/1000}')" \
        "$count"
}

while IFS= read -r line; do
    if [[ "$line" =~ "=== TYPE="([a-z]+)" RANGE_SIZE="([0-9]+)" ===" ]]; then
        if [ -n "$CURRENT_LABEL" ] && [ ${#TIMES[@]} -gt 0 ]; then
            parse_and_print "$CURRENT_LABEL" "${TIMES[@]}"
        fi
        local_type="${BASH_REMATCH[1]}"
        local_range="${BASH_REMATCH[2]}"
        CURRENT_LABEL="${local_type} range=${local_range}"
        TIMES=()
    elif [[ "$line" =~ Time:\ ([0-9.]+)\ ms ]]; then
        TIMES+=("${BASH_REMATCH[1]}")
    fi
done <<< "$OUTPUT"

# Print last group
if [ -n "$CURRENT_LABEL" ] && [ ${#TIMES[@]} -gt 0 ]; then
    parse_and_print "$CURRENT_LABEL" "${TIMES[@]}"
fi

echo ""
echo "=== Test Complete ==="
