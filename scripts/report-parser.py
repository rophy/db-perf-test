#!/usr/bin/env python3
"""Parse benchmark report folder for per-interval sysbench metrics."""

import json
import os
import re
import sys


def parse_node_spec(report_path):
    """Parse RUN_NODE_SPEC.txt for tserver pod to node mapping with resources"""
    spec_path = os.path.join(report_path, 'RUN_NODE_SPEC.txt')

    if not os.path.exists(spec_path):
        return

    with open(spec_path, 'r') as f:
        lines = f.read().strip().split('\n')

    if len(lines) < 2:
        return

    data_lines = lines[1:]

    print("=== Tserver Node Specs ===")
    print(f"Tservers: {len(data_lines)}")
    for line in data_lines:
        parts = line.split('\t')
        if len(parts) >= 4:
            pod_name, node_name, cpu, memory = parts[0], parts[1], parts[2], parts[3]
            print(f"  {pod_name} -> {node_name}: {cpu} CPU, {memory}")


def read_times(report_path):
    """Return (run_start, warmup_end, run_end) in epoch seconds, or (None, None, None)."""
    path = os.path.join(report_path, 'sysbench_times.txt')
    if not os.path.exists(path):
        return None, None, None
    values = {}
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if '=' not in line:
                continue
            k, v = line.split('=', 1)
            try:
                values[k.strip()] = int(v.strip())
            except ValueError:
                pass
    return (
        values.get('RUN_START_TIME'),
        values.get('WARMUP_END_TIME'),
        values.get('RUN_END_TIME'),
    )


def read_intervals(report_path):
    """Extract the embedded sysbenchIntervals JSON array from report.html."""
    html_path = os.path.join(report_path, 'report.html')
    if not os.path.exists(html_path):
        return []
    with open(html_path, 'r') as f:
        content = f.read()
    m = re.search(r'const\s+sysbenchIntervals\s*=\s*(\[.*?\]);', content, re.DOTALL)
    if not m:
        return []
    try:
        return json.loads(m.group(1))
    except json.JSONDecodeError:
        return []


def print_interval_table(intervals, warmup_len):
    """Print per-interval table. warmup_len is seconds; None disables Phase column."""
    print("\n=== Sysbench Per-Interval Metrics ===")
    if not intervals:
        print("(no interval data found)")
        return

    header = f"{'T(s)':>4}  {'Phase':<6}  {'TPS':>8}  {'p95(ms)':>8}  {'err/s':>6}  {'CPU%':>5}  {'Mem(MB)':>8}  {'Net(MB/s)':>9}  {'WrIOPS':>7}  {'CliCPU':>6}"
    print(header)
    print('-' * len(header))
    for iv in intervals:
        t = iv.get('time', 0)
        phase = '-'
        if warmup_len is not None:
            phase = 'warmup' if t <= warmup_len else 'run'
        tps = iv.get('tps', 0) or 0
        lat = iv.get('lat_95', 0) or 0
        err = iv.get('err_s', 0) or 0
        cpu = iv.get('cpu_pct')
        mem = iv.get('mem_mb')
        net = iv.get('net_mb')
        wio = iv.get('disk_write_iops')
        cli = iv.get('client_cpu_cores')

        cpu_s = f"{cpu:5.1f}" if cpu is not None else "  -  "
        mem_s = f"{mem:8,.0f}" if mem is not None else "     -  "
        net_s = f"{net:9.1f}" if net is not None else "      -  "
        wio_s = f"{wio:7,.0f}" if wio is not None else "     -  "
        cli_s = f"{cli:6.2f}" if cli is not None else "   -  "
        print(f"{t:4d}  {phase:<6}  {tps:8,.0f}  {lat:8.1f}  {err:6.2f}  {cpu_s}  {mem_s}  {net_s}  {wio_s}  {cli_s}")


def parse_sysbench_totals(report_path):
    """Print sysbench-reported totals from sysbench_output.txt (includes warmup)."""
    sysbench_path = os.path.join(report_path, 'sysbench_output.txt')
    if not os.path.exists(sysbench_path):
        return

    with open(sysbench_path, 'r') as f:
        content = f.read()

    tps = re.search(r'transactions:\s+(\d+)\s+\(([\d.]+) per sec\.\)', content)
    qps = re.search(r'queries:\s+(\d+)\s+\(([\d.]+) per sec\.\)', content)
    errs = re.search(r'ignored errors:\s+(\d+)\s+\(([\d.]+) per sec\.\)', content)
    recs = re.search(r'reconnects:\s+(\d+)\s+\(([\d.]+) per sec\.\)', content)
    p95 = re.search(r'95th percentile:\s+([\d.]+)', content)
    elapsed = re.search(r'time elapsed:\s+([\d.]+)s', content)

    print("\n=== Sysbench Totals (as reported by sysbench; INCLUDES warmup) ===")
    print("NOTE: these are run-averaged over warmup+run. For steady-state numbers,")
    print("      read the per-interval table above and eyeball the post-warmup rows.")
    if tps:
        print(f"  TPS avg:      {float(tps.group(2)):>12,.2f}  (total txns: {int(tps.group(1)):,})")
    if qps:
        print(f"  QPS avg:      {float(qps.group(2)):>12,.2f}  (total qrys: {int(qps.group(1)):,})")
    if p95:
        print(f"  p95 latency:  {float(p95.group(1)):>12,.2f} ms")
    if errs:
        print(f"  Errors:       {int(errs.group(1)):>12,}  ({float(errs.group(2)):.2f}/s)")
    if recs:
        print(f"  Reconnects:   {int(recs.group(1)):>12,}  ({float(recs.group(2)):.2f}/s)")
    if elapsed:
        print(f"  Elapsed:      {float(elapsed.group(1)):>12,.1f} s")


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path/to/report/folder>", file=sys.stderr)
        sys.exit(1)

    report_path = sys.argv[1]
    if not os.path.isdir(report_path):
        print(f"Error: {report_path} is not a directory", file=sys.stderr)
        sys.exit(1)

    run_start, warmup_end, _run_end = read_times(report_path)
    warmup_len = (warmup_end - run_start) if (run_start and warmup_end) else None

    parse_node_spec(report_path)
    intervals = read_intervals(report_path)
    print_interval_table(intervals, warmup_len)
    parse_sysbench_totals(report_path)


if __name__ == '__main__':
    main()
