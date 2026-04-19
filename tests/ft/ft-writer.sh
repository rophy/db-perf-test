#!/bin/bash
set -euo pipefail

# Continuous insert writer for fault tolerance testing.
# Inserts rows into ft_test table and logs results to a journal file.
#
# Usage: ft-writer.sh <journal_file>
# Stop: kill the process or send SIGTERM

KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-virsh}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
WRITER_ID="${WRITER_ID:-1}"
INSERT_INTERVAL_MS="${INSERT_INTERVAL_MS:-100}"

JOURNAL_FILE="${1:?Usage: ft-writer.sh <journal_file>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ysqlsh command via tserver pod
YSQLSH="kubectl --context $KUBE_CONTEXT -n $NAMESPACE exec yb-tserver-0 -c yb-tserver -- /home/yugabyte/bin/ysqlsh -h yb-tserver-service -t -A"

# Create table if not exists
$YSQLSH -c "
CREATE TABLE IF NOT EXISTS ft_test (
    id SERIAL PRIMARY KEY,
    writer_id INT NOT NULL,
    seq_num INT NOT NULL,
    payload VARCHAR(64) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
TRUNCATE ft_test;
" 2>/dev/null

echo "timestamp,writer_id,seq_num,status" > "$JOURNAL_FILE"
echo "Writer $WRITER_ID started, journal: $JOURNAL_FILE"

seq_num=0
running=true

trap 'running=false; echo "Writer $WRITER_ID stopping..."' SIGTERM SIGINT

interval_s=$(awk "BEGIN {printf \"%.3f\", $INSERT_INTERVAL_MS / 1000}")

while $running; do
    seq_num=$((seq_num + 1))
    ts=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')
    payload=$(echo -n "${WRITER_ID}:${seq_num}" | md5sum | awk '{print $1}')

    result=$($YSQLSH -c "
        INSERT INTO ft_test (writer_id, seq_num, payload)
        VALUES ($WRITER_ID, $seq_num, '$payload')
        RETURNING id;
    " 2>&1) && status="OK" || status="ERROR:$(echo "$result" | tr '\n' ' ' | head -c 200)"

    echo "${ts},${WRITER_ID},${seq_num},${status}" >> "$JOURNAL_FILE"

    sleep "$interval_s" 2>/dev/null || true
done

echo "Writer $WRITER_ID stopped after $seq_num inserts"
