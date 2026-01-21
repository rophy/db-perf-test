#!/usr/bin/env python3
"""Parse benchmark report folder for tserver metrics and sysbench results"""

import json
import re
import sys
import os

def parse_node_spec(report_path):
    """Parse RUN_NODE_SPEC.txt for tserver pod to node mapping with resources"""
    spec_path = os.path.join(report_path, 'RUN_NODE_SPEC.txt')

    if not os.path.exists(spec_path):
        return

    with open(spec_path, 'r') as f:
        lines = f.read().strip().split('\n')

    if len(lines) < 2:  # Need header + at least one data row
        return

    # Skip header line
    data_lines = lines[1:]

    print("=== Tserver Node Specs ===")
    print(f"Tservers: {len(data_lines)}")
    for line in data_lines:
        parts = line.split('\t')
        if len(parts) >= 4:
            pod_name, node_name, cpu, memory = parts[0], parts[1], parts[2], parts[3]
            print(f"  {pod_name} -> {node_name}: {cpu} CPU, {memory}")


def parse_metrics(report_path):
    """Parse report.html for tserver metrics"""
    html_path = os.path.join(report_path, 'report.html')

    with open(html_path, 'r') as f:
        content = f.read()

    match = re.search(r'metricsData = ({.*?});', content, re.DOTALL)
    if not match:
        print("Error: Could not find metricsData in report.html", file=sys.stderr)
        return

    data = json.loads(match.group(1))

    def get_tserver_avg(metric_name):
        """Get average values for tserver pods"""
        metric = data.get(metric_name, {})
        values = []
        for series in metric.get('series', []):
            if 'tserver' in series['name']:
                vals = series['values']
                values.append(sum(vals) / len(vals))
        return values

    tserver_cpu = get_tserver_avg('cpu')
    tserver_memory = get_tserver_avg('memory')
    tserver_net_rx = get_tserver_avg('network_rx')
    tserver_net_tx = get_tserver_avg('network_tx')
    tserver_disk_read = get_tserver_avg('disk_read_iops')
    tserver_disk_write = get_tserver_avg('disk_write_iops')

    print("=== Tserver Metrics ===")
    print(f"Tservers: {len(tserver_cpu)}")
    if tserver_cpu:
        print(f"CPU: {sum(tserver_cpu)/len(tserver_cpu):.1f}%")
    if tserver_memory:
        print(f"Memory: {sum(tserver_memory)/len(tserver_memory):.0f} MB")
    if tserver_net_rx and tserver_net_tx:
        avg_rx = sum(tserver_net_rx) / len(tserver_net_rx) / 1024 / 1024
        avg_tx = sum(tserver_net_tx) / len(tserver_net_tx) / 1024 / 1024
        print(f"Network: RX {avg_rx:.1f} MB/s, TX {avg_tx:.1f} MB/s")
    if tserver_disk_read and tserver_disk_write:
        avg_read = sum(tserver_disk_read) / len(tserver_disk_read)
        avg_write = sum(tserver_disk_write) / len(tserver_disk_write)
        print(f"Disk IOPS: Read {avg_read:.0f}, Write {avg_write:.0f}")


def parse_sysbench(report_path):
    """Parse sysbench_output.txt for benchmark results"""
    sysbench_path = os.path.join(report_path, 'sysbench_output.txt')

    with open(sysbench_path, 'r') as f:
        content = f.read()

    # Parse transactions per sec
    tps_match = re.search(r'transactions:\s+(\d+)\s+\(([\d.]+) per sec\.\)', content)
    # Parse queries per sec
    qps_match = re.search(r'queries:\s+(\d+)\s+\(([\d.]+) per sec\.\)', content)
    # Parse errors (with rate)
    errors_match = re.search(r'ignored errors:\s+(\d+)\s+\(([\d.]+) per sec\.\)', content)
    # Parse reconnects (with rate)
    reconnects_match = re.search(r'reconnects:\s+(\d+)\s+\(([\d.]+) per sec\.\)', content)
    # Parse 95th percentile latency
    latency_match = re.search(r'95th percentile:\s+([\d.]+)', content)
    # Parse execution time
    time_match = re.search(r'time elapsed:\s+([\d.]+)s', content)

    print("\n=== Sysbench Results ===")
    if tps_match:
        print(f"TPS: {float(tps_match.group(2)):.2f}")
    if qps_match:
        print(f"QPS: {float(qps_match.group(2)):.2f}")
    if errors_match:
        errors = int(errors_match.group(1))
        error_rate = float(errors_match.group(2))
        print(f"Errors: {errors} ({error_rate:.2f}/s)")
    if reconnects_match:
        print(f"Reconnects: {reconnects_match.group(1)} ({float(reconnects_match.group(2)):.2f}/s)")
    if latency_match:
        print(f"Latency (95th): {float(latency_match.group(1)):.2f} ms")
    if time_match:
        print(f"Duration: {float(time_match.group(1)):.1f}s")


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path/to/report/folder>", file=sys.stderr)
        print(f"Example: {sys.argv[0]} reports/20260121_0643", file=sys.stderr)
        sys.exit(1)

    report_path = sys.argv[1]

    if not os.path.isdir(report_path):
        print(f"Error: {report_path} is not a directory", file=sys.stderr)
        sys.exit(1)

    parse_node_spec(report_path)
    parse_metrics(report_path)
    parse_sysbench(report_path)


if __name__ == '__main__':
    main()
