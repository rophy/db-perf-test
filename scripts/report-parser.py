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
    """Return dict of timestamp/config values from sysbench_times.txt."""
    path = os.path.join(report_path, 'sysbench_times.txt')
    if not os.path.exists(path):
        return {}
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
    return values


def parse_sysbench_spec(report_path):
    """Print sysbench pod-to-node mapping from SYSBENCH_NODE_SPEC.txt."""
    spec_path = os.path.join(report_path, 'SYSBENCH_NODE_SPEC.txt')
    if not os.path.exists(spec_path):
        return

    with open(spec_path, 'r') as f:
        lines = f.read().strip().split('\n')

    if len(lines) < 2:
        return

    data_lines = lines[1:]
    print(f"\n=== Sysbench Clients ===")
    print(f"Pods: {len(data_lines)}")
    for line in data_lines:
        parts = line.split('\t')
        if len(parts) >= 2:
            print(f"  {parts[0]} -> {parts[1]}")


INTERVAL_RE = re.compile(
    r'\[\s*(\d+)s\s*\]\s*thds:\s*\d+\s*tps:\s*([\d.]+)\s*qps:\s*[\d.]+\s*'
    r'\(r/w/o:\s*[\d.]+/[\d.]+/[\d.]+\)\s*lat\s*\(ms,95%\):\s*([\d.]+)\s*'
    r'err/s:\s*([\d.]+)'
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


def read_per_pod_intervals(report_path):
    """Read per-pod sysbench_output_N.txt files. Returns list of {time -> {tps, lat_95, err_s}}."""
    pods = []
    i = 0
    while True:
        path = os.path.join(report_path, f'sysbench_output_{i}.txt')
        if not os.path.exists(path):
            break
        with open(path) as f:
            text = f.read()
        by_time = {}
        for m in INTERVAL_RE.finditer(text):
            by_time[int(m.group(1))] = {
                'tps': float(m.group(2)),
                'lat_95': float(m.group(3)),
                'err_s': float(m.group(4)),
            }
        pods.append(by_time)
        i += 1
    return pods


def print_interval_table(intervals, warmup_len, per_pod=None):
    """Print per-interval table. warmup_len is seconds; None disables Phase column.
    per_pod is a list of per-pod interval dicts (from read_per_pod_intervals)."""
    print("\n=== Sysbench Per-Interval Metrics ===")
    if not intervals:
        print("(no interval data found)")
        return

    multi = per_pod and len(per_pod) > 1

    if multi:
        header = f"{'T(s)':>4}  {'Phase':<6}  {'TPS':>20}  {'p95(ms)':>20}  {'err/s':>13}  {'CPU%':>5}  {'Mem(MB)':>8}  {'Net(MB/s)':>9}  {'WrIOPS':>7}  {'CliCPU':>6}"
    else:
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

        if multi:
            pod_tps = [p.get(t, {}).get('tps') for p in per_pod]
            pod_lat = [p.get(t, {}).get('lat_95') for p in per_pod]
            pod_err = [p.get(t, {}).get('err_s') for p in per_pod]
            tps_s = '/'.join(f'{v:,.0f}' if v is not None else '-' for v in pod_tps)
            lat_s = '/'.join(f'{v:.0f}' if v is not None else '-' for v in pod_lat)
            err_s = '/'.join(f'{v:.1f}' if v is not None else '-' for v in pod_err)
            print(f"{t:4d}  {phase:<6}  {tps_s:>20}  {lat_s:>20}  {err_s:>13}  {cpu_s}  {mem_s}  {net_s}  {wio_s}  {cli_s}")
        else:
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

    times = read_times(report_path)
    run_start = times.get('RUN_START_TIME')
    warmup_end = times.get('WARMUP_END_TIME')
    warmup_len = (warmup_end - run_start) if (run_start and warmup_end) else None

    parse_node_spec(report_path)
    parse_sysbench_spec(report_path)
    intervals = read_intervals(report_path)
    per_pod = read_per_pod_intervals(report_path)
    print_interval_table(intervals, warmup_len, per_pod)
    parse_sysbench_totals(report_path)


if __name__ == '__main__':
    main()
