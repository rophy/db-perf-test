#!/bin/bash
set -euo pipefail

# Verifies data consistency after fault tolerance test.
# Compares writer journal against actual database contents.
#
# Usage: ft-verify.sh <journal_file> [report_dir]

KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-virsh}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"

JOURNAL_FILE="${1:?Usage: ft-verify.sh <journal_file> [report_dir]}"
REPORT_DIR="${2:-}"

if [ ! -f "$JOURNAL_FILE" ]; then
    echo "ERROR: Journal file not found: $JOURNAL_FILE" >&2
    exit 1
fi

YSQLSH="kubectl --context $KUBE_CONTEXT -n $NAMESPACE exec yb-tserver-0 -c yb-tserver -- /home/yugabyte/bin/ysqlsh -h yb-tserver-service -t -A"

echo "=== Fault Tolerance Verification ==="
echo "Journal: $JOURNAL_FILE"
echo ""

# --- Parse journal ---
total_inserts=$(tail -n +2 "$JOURNAL_FILE" | wc -l)
committed=$(tail -n +2 "$JOURNAL_FILE" | grep -c ',OK$' || true)
failed=$(tail -n +2 "$JOURNAL_FILE" | grep -c ',ERROR:' || true)

echo "Journal summary:"
echo "  Total insert attempts: $total_inserts"
echo "  Committed (OK): $committed"
echo "  Failed (ERROR): $failed"
echo ""

# Extract committed seq_nums per writer
committed_seqs=$(tail -n +2 "$JOURNAL_FILE" | grep ',OK$' | awk -F, '{print $2 ":" $3}' | sort -t: -k1,1n -k2,2n)

# --- Query database ---
echo "Querying database..."
db_rows=$($YSQLSH -c "SELECT writer_id, seq_num, payload FROM ft_test ORDER BY writer_id, seq_num;" 2>/dev/null)
db_count=$($YSQLSH -c "SELECT COUNT(*) FROM ft_test;" 2>/dev/null | tr -d ' ')

echo "  Rows in database: $db_count"
echo "  Expected (committed): $committed"
echo ""

# --- Verify committed rows exist in DB ---
echo "Verifying committed rows..."
missing=0
corrupted=0
missing_list=""

while IFS=: read -r writer_id seq_num; do
    expected_payload=$(echo -n "${writer_id}:${seq_num}" | md5sum | awk '{print $1}')

    # Check if row exists with correct payload (exact match on writer_id and seq_num, first match only)
    row=$(echo "$db_rows" | awk -F'|' -v w="$writer_id" -v s="$seq_num" '$1==w && $2==s {print; exit}' || true)

    if [ -z "$row" ]; then
        missing=$((missing + 1))
        missing_list="${missing_list}  writer=${writer_id} seq=${seq_num}\n"
    else
        actual_payload=$(echo "$row" | awk -F'|' '{print $3}')
        if [ "$actual_payload" != "$expected_payload" ]; then
            corrupted=$((corrupted + 1))
            echo "  CORRUPT: writer=$writer_id seq=$seq_num expected=$expected_payload got=$actual_payload"
        fi
    fi
done <<< "$committed_seqs"

# --- Check for extra rows (uncommitted but present) ---
extra=$((db_count - committed))
if [ "$extra" -lt 0 ]; then
    extra=0
fi

# --- Report ---
echo ""
echo "=== Verification Results ==="
echo ""

pass=true

if [ "$missing" -gt 0 ]; then
    echo "FAIL: $missing committed rows MISSING from database"
    echo -e "$missing_list"
    pass=false
else
    echo "PASS: All $committed committed rows present"
fi

if [ "$corrupted" -gt 0 ]; then
    echo "FAIL: $corrupted rows have CORRUPTED payloads"
    pass=false
else
    echo "PASS: All payloads intact (checksum verified)"
fi

if [ "$extra" -gt 0 ]; then
    echo "INFO: $extra extra rows in DB (uncommitted but persisted — acceptable)"
fi

echo ""
if [ "$pass" = true ]; then
    echo "RESULT: PASS"
    echo "  $committed/$committed committed rows verified, 0 missing, 0 corrupted"
else
    echo "RESULT: FAIL"
    echo "  $missing missing, $corrupted corrupted out of $committed committed"
fi

# --- Save report ---
if [ -n "$REPORT_DIR" ]; then
    mkdir -p "$REPORT_DIR"
    cat > "$REPORT_DIR/verify-result.txt" << EOF
Verification: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Journal: $JOURNAL_FILE
Total inserts: $total_inserts
Committed: $committed
Failed: $failed
DB rows: $db_count
Missing: $missing
Corrupted: $corrupted
Extra: $extra
Result: $([ "$pass" = true ] && echo "PASS" || echo "FAIL")
EOF
    echo ""
    echo "Report saved to: $REPORT_DIR/verify-result.txt"
fi

# Exit with appropriate code
[ "$pass" = true ] && exit 0 || exit 1
