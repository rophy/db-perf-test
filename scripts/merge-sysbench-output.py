#!/usr/bin/env python3
"""Merge multiple sysbench output files into a single combined output.

Used by sysbench-run-with-timestamps.sh when running multiple sysbench pods
in parallel. Produces a file in the exact same format as a single sysbench
run so the downstream report pipeline works unmodified.
"""

import argparse
import re
import sys
from collections import defaultdict


INTERVAL_RE = re.compile(
    r'\[\s*(\d+)s\s*\]\s*thds:\s*(\d+)\s*tps:\s*([\d.]+)\s*qps:\s*([\d.]+)\s*'
    r'\(r/w/o:\s*([\d.]+)/([\d.]+)/([\d.]+)\)\s*lat\s*\(ms,95%\):\s*([\d.]+)\s*'
    r'err/s:\s*([\d.]+)\s*reconn/s:\s*([\d.]+)'
)


def parse_intervals(text):
    intervals = {}
    for m in INTERVAL_RE.finditer(text):
        t = int(m.group(1))
        intervals[t] = {
            "time": t,
            "threads": int(m.group(2)),
            "tps": float(m.group(3)),
            "qps": float(m.group(4)),
            "read_qps": float(m.group(5)),
            "write_qps": float(m.group(6)),
            "other_qps": float(m.group(7)),
            "lat_95": float(m.group(8)),
            "err_s": float(m.group(9)),
            "reconn_s": float(m.group(10)),
        }
    return intervals


def parse_totals(text):
    totals = {}

    for key in ["read", "write", "other", "total"]:
        m = re.search(rf'^\s*{key}:\s+(\d+)', text, re.MULTILINE)
        if m:
            totals[f"sql_{key}"] = int(m.group(1))

    m = re.search(r'transactions:\s+(\d+)\s+\(([\d.]+) per sec\.\)', text)
    if m:
        totals["transactions"] = int(m.group(1))
        totals["tps"] = float(m.group(2))

    m = re.search(r'queries:\s+(\d+)\s+\(([\d.]+) per sec\.\)', text)
    if m:
        totals["queries"] = int(m.group(1))
        totals["qps"] = float(m.group(2))

    m = re.search(r'ignored errors:\s+(\d+)\s+\(([\d.]+) per sec\.\)', text)
    if m:
        totals["errors"] = int(m.group(1))
        totals["errors_ps"] = float(m.group(2))

    m = re.search(r'reconnects:\s+(\d+)\s+\(([\d.]+) per sec\.\)', text)
    if m:
        totals["reconnects"] = int(m.group(1))
        totals["reconnects_ps"] = float(m.group(2))

    m = re.search(r'events/s \(eps\):\s+([\d.]+)', text)
    if m:
        totals["eps"] = float(m.group(1))

    m = re.search(r'time elapsed:\s+([\d.]+)', text)
    if m:
        totals["elapsed"] = float(m.group(1))

    m = re.search(r'total number of events:\s+(\d+)', text)
    if m:
        totals["total_events"] = int(m.group(1))

    for key, label in [("min", "lat_min"), ("avg", "lat_avg"), ("max", "lat_max"),
                        ("95th percentile", "lat_p95"), ("sum", "lat_sum")]:
        m = re.search(rf'^\s*{re.escape(key)}:\s+([\d.]+)', text, re.MULTILINE)
        if m:
            totals[label] = float(m.group(1))

    m = re.search(r'events \(avg/stddev\):\s+([\d.]+)/([\d.]+)', text)
    if m:
        totals["fair_events_avg"] = float(m.group(1))
        totals["fair_events_stddev"] = float(m.group(2))

    m = re.search(r'execution time \(avg/stddev\):\s+([\d.]+)/([\d.]+)', text)
    if m:
        totals["fair_time_avg"] = float(m.group(1))
        totals["fair_time_stddev"] = float(m.group(2))

    # Parse thread count from header
    m = re.search(r'Number of threads:\s+(\d+)', text)
    if m:
        totals["threads"] = int(m.group(1))

    return totals


def merge_intervals(all_intervals):
    all_times = sorted(set(t for iv in all_intervals for t in iv))
    merged = []
    for t in all_times:
        row = {
            "time": t,
            "threads": 0,
            "tps": 0.0,
            "qps": 0.0,
            "read_qps": 0.0,
            "write_qps": 0.0,
            "other_qps": 0.0,
            "lat_95": 0.0,
            "err_s": 0.0,
            "reconn_s": 0.0,
        }
        for iv in all_intervals:
            if t not in iv:
                continue
            pod = iv[t]
            row["threads"] += pod["threads"]
            row["tps"] += pod["tps"]
            row["qps"] += pod["qps"]
            row["read_qps"] += pod["read_qps"]
            row["write_qps"] += pod["write_qps"]
            row["other_qps"] += pod["other_qps"]
            row["lat_95"] = max(row["lat_95"], pod["lat_95"])
            row["err_s"] += pod["err_s"]
            row["reconn_s"] += pod["reconn_s"]
        merged.append(row)
    return merged


def merge_totals(all_totals):
    m = {}
    n = len(all_totals)
    total_threads = sum(t.get("threads", 0) for t in all_totals)

    for key in ["sql_read", "sql_write", "sql_other", "sql_total",
                "transactions", "queries", "errors", "reconnects", "total_events"]:
        m[key] = sum(t.get(key, 0) for t in all_totals)

    m["elapsed"] = max(t.get("elapsed", 0) for t in all_totals)

    if m["elapsed"] > 0:
        m["tps"] = m["transactions"] / m["elapsed"]
        m["qps"] = m["queries"] / m["elapsed"]
        m["errors_ps"] = m["errors"] / m["elapsed"]
        m["reconnects_ps"] = m["reconnects"] / m["elapsed"]
        m["eps"] = m["total_events"] / m["elapsed"]
    else:
        m["tps"] = m["qps"] = m["errors_ps"] = m["reconnects_ps"] = m["eps"] = 0

    m["lat_min"] = min(t.get("lat_min", 0) for t in all_totals)
    m["lat_max"] = max(t.get("lat_max", 0) for t in all_totals)
    m["lat_p95"] = max(t.get("lat_p95", 0) for t in all_totals)
    m["lat_sum"] = sum(t.get("lat_sum", 0) for t in all_totals)

    total_txns = sum(t.get("transactions", 0) for t in all_totals)
    if total_txns > 0:
        m["lat_avg"] = sum(t.get("lat_avg", 0) * t.get("transactions", 0) for t in all_totals) / total_txns
    else:
        m["lat_avg"] = 0

    m["threads"] = total_threads
    if total_threads > 0:
        m["fair_events_avg"] = m["total_events"] / total_threads
    else:
        m["fair_events_avg"] = 0
    m["fair_events_stddev"] = 0.0

    if total_threads > 0:
        m["fair_time_avg"] = sum(t.get("fair_time_avg", 0) * t.get("threads", 0) for t in all_totals) / total_threads
    else:
        m["fair_time_avg"] = 0
    m["fair_time_stddev"] = 0.0

    return m


def format_interval(iv):
    return (
        f'[ {iv["time"]}s ] thds: {iv["threads"]} '
        f'tps: {iv["tps"]:.2f} qps: {iv["qps"]:.2f} '
        f'(r/w/o: {iv["read_qps"]:.2f}/{iv["write_qps"]:.2f}/{iv["other_qps"]:.2f}) '
        f'lat (ms,95%): {iv["lat_95"]:.2f} err/s: {iv["err_s"]:.2f} reconn/s: {iv["reconn_s"]:.2f}'
    )


def format_output(header_text, intervals, totals, num_pods):
    lines = []

    lines.append(header_text.rstrip())
    lines.append("")

    for iv in intervals:
        lines.append(format_interval(iv))

    lines.append("SQL statistics:")
    lines.append("    queries performed:")
    lines.append(f'        read:                            {totals.get("sql_read", 0)}')
    lines.append(f'        write:                           {totals.get("sql_write", 0)}')
    lines.append(f'        other:                           {totals.get("sql_other", 0)}')
    lines.append(f'        total:                           {totals.get("sql_total", 0)}')
    lines.append(f'    transactions:                        {totals["transactions"]} ({totals["tps"]:.2f} per sec.)')
    lines.append(f'    queries:                             {totals["queries"]} ({totals["qps"]:.2f} per sec.)')
    lines.append(f'    ignored errors:                      {totals["errors"]}      ({totals["errors_ps"]:.2f} per sec.)')
    lines.append(f'    reconnects:                          {totals["reconnects"]}      ({totals["reconnects_ps"]:.2f} per sec.)')
    lines.append("")
    lines.append("Throughput:")
    lines.append(f'    events/s (eps):                      {totals["eps"]:.4f}')
    lines.append(f'    time elapsed:                        {totals["elapsed"]:.4f}s')
    lines.append(f'    total number of events:              {totals["total_events"]}')
    lines.append("")
    lines.append("Latency (ms):")
    lines.append(f'         min:                                  {totals["lat_min"]:>8.2f}')
    lines.append(f'         avg:                                  {totals["lat_avg"]:>8.2f}')
    lines.append(f'         max:                                  {totals["lat_max"]:>8.2f}')
    lines.append(f'         95th percentile:                      {totals["lat_p95"]:>8.2f}')
    lines.append(f'         sum:                            {totals["lat_sum"]:.2f}')
    lines.append("")
    lines.append("Threads fairness:")
    lines.append(f'    events (avg/stddev):           {totals["fair_events_avg"]:.4f}/{totals["fair_events_stddev"]:.2f}')
    lines.append(f'    execution time (avg/stddev):   {totals["fair_time_avg"]:.4f}/{totals["fair_time_stddev"]:.2f}')
    lines.append("")
    return "\n".join(lines)


def extract_header(text):
    """Extract everything before the first interval line."""
    m = re.search(r'\[\s*\d+s\s*\]', text)
    if m:
        return text[:m.start()].rstrip()
    # No intervals found — return up to SQL statistics
    m = re.search(r'^SQL statistics:', text, re.MULTILINE)
    if m:
        return text[:m.start()].rstrip()
    return text[:200]


def main():
    parser = argparse.ArgumentParser(description="Merge multiple sysbench output files")
    parser.add_argument("inputs", nargs="+", help="Input sysbench_output_N.txt files")
    parser.add_argument("-o", "--output", required=True, help="Output merged file")
    args = parser.parse_args()

    all_texts = []
    for path in args.inputs:
        with open(path) as f:
            all_texts.append(f.read())

    all_intervals = [parse_intervals(t) for t in all_texts]
    all_totals_parsed = [parse_totals(t) for t in all_texts]

    merged_intervals = merge_intervals(all_intervals)
    merged_totals = merge_totals(all_totals_parsed)

    header = extract_header(all_texts[0])
    # Update the header to reflect merged state
    total_threads = merged_totals.get("threads", 0)
    num_pods = len(args.inputs)
    per_pod = total_threads // num_pods if num_pods > 0 else total_threads
    header = re.sub(r'Threads: \d+', f'Threads: {total_threads} ({num_pods} pods x {per_pod})', header)
    header = re.sub(r'Number of threads: \d+', f'Number of threads: {total_threads}', header)

    output = format_output(header, merged_intervals, merged_totals, num_pods)

    with open(args.output, "w") as f:
        f.write(output)

    print(f"Merged {num_pods} outputs -> {args.output} (total threads: {total_threads}, "
          f"intervals: {len(merged_intervals)})")


if __name__ == "__main__":
    main()
