#!/usr/bin/env python3
"""
Stress Test Report Generator for YugabyteDB Sysbench Benchmarks

Generates HTML reports with Chart.js visualizations from Prometheus metrics.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional
from urllib.parse import quote

# Jinja2 for templating
try:
    from jinja2 import Template
except ImportError:
    print("Error: Jinja2 is required. Install with: pip install Jinja2")
    sys.exit(1)


@dataclass
class MetricSeries:
    """Represents a time series of metric values."""
    name: str
    labels: dict
    timestamps: list[float] = field(default_factory=list)
    values: list[float] = field(default_factory=list)

    def min_value(self) -> float:
        non_zero = [v for v in self.values if v > 0]
        return min(non_zero) if non_zero else 0

    def max_value(self) -> float:
        return max(self.values) if self.values else 0

    def avg_value(self) -> float:
        non_zero = [v for v in self.values if v > 0]
        return sum(non_zero) / len(non_zero) if non_zero else 0

    def total_value(self, duration_seconds: float) -> float:
        """Calculate total based on average rate * duration."""
        return self.avg_value() * duration_seconds


@dataclass
class ReportConfig:
    """Configuration for report generation."""
    start_time: float
    end_time: float
    warmup_end: Optional[float] = None
    step: int = 30
    kube_context: str = "minikube"
    namespace: str = "yugabyte-test"
    release_name: str = "yb-bench"
    prometheus_url: str = "http://yb-bench-prometheus:9090"
    pods: list[str] = field(default_factory=list)
    rate_metrics: list[str] = field(default_factory=list)
    total_metrics: list[str] = field(default_factory=list)
    title: str = "Sysbench Stress Test Report"
    output_dir: str = "reports"

    @property
    def duration_seconds(self) -> float:
        return self.end_time - self.start_time


class QueryExecutor:
    """Executes queries via kubectl exec using wget."""

    def __init__(self, kube_context: str, namespace: str, release_name: str = "yb-bench"):
        self.kube_context = kube_context
        self.namespace = namespace
        self.release_name = release_name

    def exec_curl(self, url: str) -> Optional[str]:
        """Execute wget command inside prometheus pod (curl not available)."""
        cmd = [
            "kubectl", "--context", self.kube_context,
            "exec", "-n", self.namespace, f"deployment/{self.release_name}-prometheus",
            "--", "wget", "-q", "-O", "-", url
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                return result.stdout
            print(f"Error executing wget: {result.stderr}", file=sys.stderr)
            return None
        except subprocess.TimeoutExpired:
            print("Query timeout", file=sys.stderr)
            return None
        except Exception as e:
            print(f"Query error: {e}", file=sys.stderr)
            return None


class PrometheusClient:
    """Client for querying Prometheus metrics."""

    def __init__(self, executor: QueryExecutor, base_url: str):
        self.executor = executor
        self.base_url = base_url

    def query_range(self, query: str, start: float, end: float, step: int) -> list[MetricSeries]:
        """Execute a range query and return metric series."""
        encoded_query = quote(query)
        url = f"{self.base_url}/api/v1/query_range?query={encoded_query}&start={start}&end={end}&step={step}"

        response = self.executor.exec_curl(url)
        if not response:
            return []

        try:
            data = json.loads(response)
            if data.get("status") != "success":
                print(f"Query failed: {data.get('error', 'unknown error')}", file=sys.stderr)
                return []

            results = []
            for result in data.get("data", {}).get("result", []):
                metric = result.get("metric", {})
                values = result.get("values", [])

                series = MetricSeries(
                    name=metric.get("__name__", query),
                    labels=metric,
                    timestamps=[float(v[0]) for v in values],
                    values=[float(v[1]) for v in values]
                )
                results.append(series)

            return results
        except json.JSONDecodeError as e:
            print(f"JSON decode error: {e}", file=sys.stderr)
            return []


class ClusterSpecCollector:
    """Collects YugabyteDB cluster specifications via kubectl."""

    def __init__(self, kube_context: str, namespace: str):
        self.kube_context = kube_context
        self.namespace = namespace

    def _run_kubectl(self, args: list[str]) -> Optional[str]:
        """Run kubectl command and return output."""
        cmd = ["kubectl", "--context", self.kube_context, "-n", self.namespace] + args
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                return result.stdout.strip()
            return None
        except Exception:
            return None

    def _get_statefulset_spec(self, name: str) -> dict:
        """Get StatefulSet specification."""
        output = self._run_kubectl([
            "get", "statefulset", name, "-o",
            "jsonpath={.spec.replicas},{.spec.template.spec.containers[0].resources.requests.cpu},"
            "{.spec.template.spec.containers[0].resources.requests.memory},"
            "{.spec.template.spec.containers[0].resources.limits.cpu},"
            "{.spec.template.spec.containers[0].resources.limits.memory}"
        ])
        if not output:
            return {}

        parts = output.split(",")
        if len(parts) >= 5:
            return {
                "replicas": int(parts[0]) if parts[0] else 0,
                "cpu_request": parts[1] or "N/A",
                "mem_request": parts[2] or "N/A",
                "cpu_limit": parts[3] or "N/A",
                "mem_limit": parts[4] or "N/A",
            }
        return {}

    def _get_pvc_info(self, label_selector: str) -> dict:
        """Get PVC information."""
        output = self._run_kubectl([
            "get", "pvc", "-l", label_selector, "-o",
            "jsonpath={.items[0].spec.storageClassName},{.items[0].spec.resources.requests.storage}"
        ])
        if not output:
            return {}

        parts = output.split(",")
        if len(parts) >= 2:
            return {
                "storage_class": parts[0] or "N/A",
                "size": parts[1] or "N/A",
            }
        return {}

    def _get_yugabyte_version(self) -> str:
        """Get YugabyteDB version from tserver pod."""
        output = self._run_kubectl([
            "get", "pod", "-l", "app=yb-tserver", "-o",
            "jsonpath={.items[0].spec.containers[0].image}"
        ])
        if output:
            # Extract version from image tag (e.g., yugabytedb/yugabyte:2.20.0.0-b100)
            if ":" in output:
                return output.split(":")[-1]
        return "N/A"

    def collect(self) -> dict:
        """Collect all cluster specifications."""
        print("Collecting cluster specifications...")

        master_spec = self._get_statefulset_spec("yb-master")
        tserver_spec = self._get_statefulset_spec("yb-tserver")
        pvc_info = self._get_pvc_info("app=yb-tserver")
        yb_version = self._get_yugabyte_version()

        return {
            "yugabyte_version": yb_version,
            "master": master_spec,
            "tserver": tserver_spec,
            "storage": pvc_info,
        }


class ReportGenerator:
    """Generates stress test reports."""

    def __init__(self, config: ReportConfig):
        self.config = config
        self.executor = QueryExecutor(config.kube_context, config.namespace, config.release_name)
        self.prometheus = PrometheusClient(self.executor, config.prometheus_url)
        self.cluster_collector = ClusterSpecCollector(config.kube_context, config.namespace)
        self.metrics_data = {}
        self.by_pod = {"master": [], "tserver": [], "other": []}
        self.by_node = {}
        self.pod_to_node = {}
        self.cluster_spec = {}

    def validate_connectivity(self):
        """Validate kubectl and prometheus connectivity before proceeding."""
        # Check kubectl can reach the cluster
        cmd = [
            "kubectl", "--context", self.config.kube_context,
            "get", "namespace", self.config.namespace,
            "-o", "name"
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode != 0:
                print(f"Error: Cannot access namespace '{self.config.namespace}' in context '{self.config.kube_context}'", file=sys.stderr)
                print(f"kubectl error: {result.stderr}", file=sys.stderr)
                sys.exit(1)
        except subprocess.TimeoutExpired:
            print(f"Error: kubectl timed out connecting to context '{self.config.kube_context}'", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"Error: kubectl failed: {e}", file=sys.stderr)
            sys.exit(1)

        # Check prometheus deployment exists
        cmd = [
            "kubectl", "--context", self.config.kube_context,
            "-n", self.config.namespace,
            "get", f"deployment/{self.config.release_name}-prometheus",
            "-o", "name"
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode != 0:
                print(f"Error: Prometheus deployment '{self.config.release_name}-prometheus' not found in namespace '{self.config.namespace}'", file=sys.stderr)
                print(f"kubectl error: {result.stderr}", file=sys.stderr)
                sys.exit(1)
        except Exception as e:
            print(f"Error: Failed to check prometheus deployment: {e}", file=sys.stderr)
            sys.exit(1)

    def collect_container_metrics(self):
        """Collect CPU, memory, network, disk metrics for pods."""
        pods_regex = "|".join(self.config.pods)
        ns = self.config.namespace

        # Sum of real per-container rows. Avoid the pod-cgroup row (container="")
        # because it drifts ~20-30% from the per-container sum under rate(). Also
        # exclude "POD" (docker/EKS pause-container label) for portability; on k3s
        # the pause container has no container label so this filter is a no-op.
        container_filter = 'container!="",container!="POD"'

        # Window for cAdvisor-sourced rates. cAdvisor refreshes its counters
        # internally only every ~10-15s regardless of Prometheus scrape_interval,
        # so a 15s window often captures fewer than 2 distinct raw samples and
        # irate returns no value. 30s reliably spans 2+ refreshes.
        cadvisor_window = "30s"

        # CPU usage (cores).
        cpu_query = (
            f'sum by (instance, pod) ('
            f'irate(container_cpu_usage_seconds_total{{namespace="{ns}",'
            f'pod=~"{pods_regex}",{container_filter}}}[{cadvisor_window}]))'
        )
        self.metrics_data["cpu"] = self._query_and_aggregate(cpu_query, "CPU Usage (cores)")

        # Memory usage (MB) — gauge, no rate. Sum per-container rows for parity
        # with the CPU query.
        mem_query = (
            f'sum by (instance, pod) ('
            f'container_memory_working_set_bytes{{namespace="{ns}",'
            f'pod=~"{pods_regex}",{container_filter}}}) / 1024 / 1024'
        )
        self.metrics_data["memory"] = self._query_and_aggregate(mem_query, "Memory Usage (MB)")

        # Network RX/TX (bytes/s) — cAdvisor only emits pod-level rows for these
        # (shared netns), so no container filter is needed.
        net_rx_query = (
            f'sum by (instance, pod) ('
            f'irate(container_network_receive_bytes_total{{namespace="{ns}",'
            f'pod=~"{pods_regex}"}}[{cadvisor_window}]))'
        )
        self.metrics_data["network_rx"] = self._query_and_aggregate(net_rx_query, "Network RX (B/s)")

        net_tx_query = (
            f'sum by (instance, pod) ('
            f'irate(container_network_transmit_bytes_total{{namespace="{ns}",'
            f'pod=~"{pods_regex}"}}[{cadvisor_window}]))'
        )
        self.metrics_data["network_tx"] = self._query_and_aggregate(net_tx_query, "Network TX (B/s)")

        # Disk Read/Write IOPS and Throughput — per-container rows with same filter.
        disk_read_iops_query = (
            f'sum by (instance, pod) ('
            f'irate(container_fs_reads_total{{namespace="{ns}",'
            f'pod=~"{pods_regex}",{container_filter}}}[{cadvisor_window}]))'
        )
        self.metrics_data["disk_read_iops"] = self._query_and_aggregate(disk_read_iops_query, "Disk Read IOPS")

        disk_write_iops_query = (
            f'sum by (instance, pod) ('
            f'irate(container_fs_writes_total{{namespace="{ns}",'
            f'pod=~"{pods_regex}",{container_filter}}}[{cadvisor_window}]))'
        )
        self.metrics_data["disk_write_iops"] = self._query_and_aggregate(disk_write_iops_query, "Disk Write IOPS")

        disk_read_throughput_query = (
            f'sum by (instance, pod) ('
            f'irate(container_fs_reads_bytes_total{{namespace="{ns}",'
            f'pod=~"{pods_regex}",{container_filter}}}[{cadvisor_window}])) / 1024 / 1024'
        )
        self.metrics_data["disk_read_throughput"] = self._query_and_aggregate(disk_read_throughput_query, "Disk Read (MB/s)")

        disk_write_throughput_query = (
            f'sum by (instance, pod) ('
            f'irate(container_fs_writes_bytes_total{{namespace="{ns}",'
            f'pod=~"{pods_regex}",{container_filter}}}[{cadvisor_window}])) / 1024 / 1024'
        )
        self.metrics_data["disk_write_throughput"] = self._query_and_aggregate(disk_write_throughput_query, "Disk Write (MB/s)")

    def collect_node_metrics(self):
        """Collect node-level CPU/memory/network/disk from node_exporter."""
        # Node CPU in cores-used, per instance.
        #   count-by-instance of idle rows  = total CPUs on that node
        #   sum-by-instance of irate(idle)  = idle cores
        #   difference                      = cores in use
        # Reported in cores so it overlays 1:1 with container CPU (also cores).
        node_cpu_query = (
            '(count by (instance) (node_cpu_seconds_total{mode="idle"})) '
            '- sum by (instance) (irate(node_cpu_seconds_total{mode="idle"}[15s]))'
        )
        self.metrics_data["node_cpu"] = self._query_and_aggregate_by_instance(node_cpu_query, "Node CPU Total (cores)")

        # CPU breakdown by mode (kept as percent — informational detail charts).
        for mode in ["user", "system", "iowait", "steal", "softirq"]:
            query = f'avg by (instance) (irate(node_cpu_seconds_total{{mode="{mode}"}}[15s])) * 100'
            self.metrics_data[f"node_cpu_{mode}"] = self._query_and_aggregate_by_instance(query, f"Node CPU {mode} (%)")

        # Node memory used (MB) = MemTotal - MemAvailable.
        node_mem_query = (
            '(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1024 / 1024'
        )
        self.metrics_data["node_memory"] = self._query_and_aggregate_by_instance(node_mem_query, "Node Memory Used (MB)")

        # Node network RX/TX across non-loopback devices (bytes/s).
        self.metrics_data["node_network_rx"] = self._query_and_aggregate_by_instance(
            'sum by (instance) (irate(node_network_receive_bytes_total{device!="lo"}[15s]))',
            "Node Network RX (B/s)",
        )
        self.metrics_data["node_network_tx"] = self._query_and_aggregate_by_instance(
            'sum by (instance) (irate(node_network_transmit_bytes_total{device!="lo"}[15s]))',
            "Node Network TX (B/s)",
        )

        # Node disk I/O summed across devices. Exclude loop/dm devices to focus
        # on physical disks; wrapped in sum-by-instance so a node with multiple
        # devices still returns one series per instance.
        disk_filter = 'device!~"loop.*|dm-.*"'
        self.metrics_data["node_disk_read_iops"] = self._query_and_aggregate_by_instance(
            f'sum by (instance) (irate(node_disk_reads_completed_total{{{disk_filter}}}[15s]))',
            "Node Disk Read IOPS",
        )
        self.metrics_data["node_disk_write_iops"] = self._query_and_aggregate_by_instance(
            f'sum by (instance) (irate(node_disk_writes_completed_total{{{disk_filter}}}[15s]))',
            "Node Disk Write IOPS",
        )
        self.metrics_data["node_disk_read_throughput"] = self._query_and_aggregate_by_instance(
            f'sum by (instance) (irate(node_disk_read_bytes_total{{{disk_filter}}}[15s])) / 1024 / 1024',
            "Node Disk Read (MB/s)",
        )
        self.metrics_data["node_disk_write_throughput"] = self._query_and_aggregate_by_instance(
            f'sum by (instance) (irate(node_disk_written_bytes_total{{{disk_filter}}}[15s])) / 1024 / 1024',
            "Node Disk Write (MB/s)",
        )

    def _query_and_aggregate_by_instance(self, query: str, display_name: str) -> dict:
        """Query metrics and aggregate results, grouped by instance (node)."""
        series_list = self.prometheus.query_range(
            query,
            self.config.start_time,
            self.config.end_time,
            self.config.step
        )

        all_values = []
        for series in series_list:
            if series.values:
                all_values.extend(series.values)

        if not all_values:
            min_val = 0
            avg_val = 0
            max_val = 0
        else:
            non_zero = [v for v in all_values if v > 0]
            min_val = min(non_zero) if non_zero else 0
            max_val = max(all_values)
            avg_val = sum(non_zero) / len(non_zero) if non_zero else 0

        total_val = avg_val * self.config.duration_seconds

        return {
            "name": display_name,
            "min": min_val,
            "avg": avg_val,
            "max": max_val,
            "total": total_val,
            "series": [
                {
                    "name": s.labels.get("instance", s.name),
                    "instance": s.labels.get("instance"),
                    "timestamps": s.timestamps,
                    "values": s.values
                }
                for s in series_list
            ]
        }

    def collect_interval_series(self, step: int) -> dict:
        """Collect single-series aggregates for the per-interval sysbench table.

        Each metric is summed/averaged across the DB tier at `step` resolution,
        so rows line up with sysbench's reportInterval.
        """
        ns = self.config.namespace
        tserver_regex = "yb-tserver.*"
        container_filter = 'container!="",container!="POD"'
        # node_cpu_seconds_total refreshes every scrape (5s); cAdvisor refreshes
        # every ~10-15s so its rate windows must be wider. See collect_container_metrics.
        node_window = "15s"
        cadvisor_window = "30s"

        queries = {
            # DB-node VM CPU in cores-used, averaged across role=db nodes.
            "cpu_cores": (
                'avg('
                'count by (instance) (node_cpu_seconds_total{mode="idle",role="db"}) '
                f'- sum by (instance) (irate(node_cpu_seconds_total{{mode="idle",role="db"}}[{node_window}])))'
            ),
            # Total tserver-container memory in MB (sum of per-container rows).
            "mem_mb": (
                f'sum(container_memory_working_set_bytes{{namespace="{ns}",'
                f'pod=~"{tserver_regex}",{container_filter}}}) / 1024 / 1024'
            ),
            # Network RX+TX MB/s across tserver pods (pod-level only — no container filter).
            "net_rx_mb": (
                f'sum(irate(container_network_receive_bytes_total{{namespace="{ns}",'
                f'pod=~"{tserver_regex}"}}[{cadvisor_window}])) / 1024 / 1024'
            ),
            "net_tx_mb": (
                f'sum(irate(container_network_transmit_bytes_total{{namespace="{ns}",'
                f'pod=~"{tserver_regex}"}}[{cadvisor_window}])) / 1024 / 1024'
            ),
            # Disk write IOPS across tserver pods.
            "disk_write_iops": (
                f'sum(irate(container_fs_writes_total{{namespace="{ns}",'
                f'pod=~"{tserver_regex}",{container_filter}}}[{cadvisor_window}]))'
            ),
            # Sysbench (client) pod CPU in cores consumed, summed across replicas.
            "client_cpu_cores": (
                f'sum(irate(container_cpu_usage_seconds_total{{namespace="{ns}",'
                f'pod=~".*sysbench.*",{container_filter}}}[{cadvisor_window}]))'
            ),
        }

        series_by_key: dict[str, dict[int, float]] = {}
        for key, q in queries.items():
            result = self.prometheus.query_range(
                q, self.config.start_time, self.config.end_time, step
            )
            if result and result[0].values:
                s = result[0]
                series_by_key[key] = {
                    int(t): v for t, v in zip(s.timestamps, s.values)
                }
            else:
                series_by_key[key] = {}
        return series_by_key

    @staticmethod
    def _nearest_value(series: dict[int, float], target_ts: int, max_skew: int):
        """Return the value in `series` whose timestamp is closest to target_ts,
        or None if no sample is within max_skew seconds."""
        if not series:
            return None
        closest = min(series.keys(), key=lambda t: abs(t - target_ts))
        if abs(closest - target_ts) > max_skew:
            return None
        return series[closest]

    def enrich_intervals_with_metrics(self, intervals: list, step: int) -> list:
        """Attach per-interval CPU/mem/net/disk samples to each sysbench row."""
        if not intervals:
            return intervals
        series = self.collect_interval_series(step)
        max_skew = max(step, 15)
        enriched = []
        for iv in intervals:
            target_ts = int(self.config.start_time + iv["time"])
            row = dict(iv)
            row["cpu_cores"] = self._nearest_value(series["cpu_cores"], target_ts, max_skew)
            row["mem_mb"] = self._nearest_value(series["mem_mb"], target_ts, max_skew)
            rx = self._nearest_value(series["net_rx_mb"], target_ts, max_skew)
            tx = self._nearest_value(series["net_tx_mb"], target_ts, max_skew)
            row["net_mb"] = (rx or 0) + (tx or 0) if (rx is not None or tx is not None) else None
            row["disk_write_iops"] = self._nearest_value(
                series["disk_write_iops"], target_ts, max_skew
            )
            row["client_cpu_cores"] = self._nearest_value(
                series["client_cpu_cores"], target_ts, max_skew
            )
            enriched.append(row)
        return enriched

    def collect_custom_metrics(self):
        """Collect custom rate and total metrics."""
        for metric_expr in self.config.rate_metrics:
            key = f"rate_{metric_expr.replace('{', '_').replace('}', '_').replace(',', '_')}"
            # 30s window is wider than cAdvisor's internal refresh cadence (~10-15s)
            # and plenty for node_exporter (5s scrapes). Works for both source types.
            query = f"sum(irate({metric_expr}[30s]))"
            self.metrics_data[key] = self._query_and_aggregate(query, f"Rate: {metric_expr}")

        for metric_expr in self.config.total_metrics:
            key = f"total_{metric_expr.replace('{', '_').replace('}', '_').replace(',', '_')}"
            query = f"sum({metric_expr})"
            self.metrics_data[key] = self._query_and_aggregate(query, f"Total: {metric_expr}")

    def _query_and_aggregate(self, query: str, display_name: str) -> dict:
        """Query metrics and aggregate results."""
        series_list = self.prometheus.query_range(
            query,
            self.config.start_time,
            self.config.end_time,
            self.config.step
        )

        # Filter to only tserver pods for summary statistics
        tserver_values = []
        for series in series_list:
            pod_name = series.labels.get("pod", "")
            if "yb-tserver" in pod_name and series.values:
                tserver_values.extend(series.values)

        # Calculate statistics from tserver pods only
        if not tserver_values:
            min_val = 0
            avg_val = 0
            max_val = 0
        else:
            non_zero = [v for v in tserver_values if v > 0]
            min_val = min(non_zero) if non_zero else 0
            max_val = max(tserver_values)
            avg_val = sum(non_zero) / len(non_zero) if non_zero else 0

        total_val = avg_val * self.config.duration_seconds

        return {
            "name": display_name,
            "min": min_val,
            "avg": avg_val,
            "max": max_val,
            "total": total_val,
            "series": [
                {
                    "name": s.labels.get("pod", s.name),
                    "pod": s.labels.get("pod"),
                    "instance": s.labels.get("instance"),
                    "timestamps": s.timestamps,
                    "values": s.values
                }
                for s in series_list
            ]
        }

    @staticmethod
    def _classify_pod(pod_name: str) -> str:
        """Bucket a pod by name prefix for the tabbed report view."""
        if pod_name.startswith("yb-master"):
            return "master"
        if pod_name.startswith("yb-tserver"):
            return "tserver"
        return "other"

    # Pod-level metric keys (cAdvisor) that carry per-pod series.
    _POD_METRIC_KEYS = (
        "cpu", "memory",
        "network_rx", "network_tx",
        "disk_read_iops", "disk_write_iops",
        "disk_read_throughput", "disk_write_throughput",
    )

    # Node-level metric keys (node_exporter) that carry per-instance series.
    _NODE_METRIC_KEYS = (
        "node_cpu", "node_memory",
        "node_network_rx", "node_network_tx",
        "node_disk_read_iops", "node_disk_write_iops",
        "node_disk_read_throughput", "node_disk_write_throughput",
    )

    def restructure_by_pod_and_node(self):
        """Reshape flat metrics into by_pod (master/tserver/other) + by_node.

        Stored on self as by_pod / by_node / pod_to_node. The flat
        metrics_data keys are left untouched — the Overview + Raw tabs and
        the Metrics Summary table still consume them directly.
        """
        pods: dict[tuple[str, str], dict] = {}
        for mkey in self._POD_METRIC_KEYS:
            metric = self.metrics_data.get(mkey)
            if not metric:
                continue
            for s in metric.get("series", []):
                pod = s.get("pod")
                instance = s.get("instance")
                if not pod:
                    continue
                card = pods.setdefault(
                    (instance or "", pod),
                    {"pod": pod, "instance": instance, "role": self._classify_pod(pod)},
                )
                card[mkey] = {
                    "timestamps": s.get("timestamps", []),
                    "values": s.get("values", []),
                }

        by_pod: dict[str, list] = {"master": [], "tserver": [], "other": []}
        for card in pods.values():
            by_pod[card["role"]].append(card)
        for role in by_pod:
            by_pod[role].sort(key=lambda c: c.get("pod", ""))

        nodes: dict[str, dict] = {}
        for mkey in self._NODE_METRIC_KEYS:
            metric = self.metrics_data.get(mkey)
            if not metric:
                continue
            for s in metric.get("series", []):
                instance = s.get("instance")
                if not instance:
                    continue
                node = nodes.setdefault(instance, {"instance": instance})
                node[mkey] = {
                    "timestamps": s.get("timestamps", []),
                    "values": s.get("values", []),
                }

        pod_to_node = {
            card["pod"]: card["instance"]
            for card in pods.values()
            if card.get("pod") and card.get("instance")
        }

        self.by_pod = by_pod
        self.by_node = nodes
        self.pod_to_node = pod_to_node

    def generate_report(self) -> str:
        """Generate HTML report."""
        # Collect cluster specifications
        self.cluster_spec = self.cluster_collector.collect()

        # Collect metrics
        print("Collecting container metrics...")
        self.collect_container_metrics()

        print("Collecting node metrics...")
        self.collect_node_metrics()

        print("Collecting custom metrics...")
        self.collect_custom_metrics()

        # Reshape flat series into by_pod / by_node views for the tabbed template.
        self.restructure_by_pod_and_node()

        # Load template
        template_path = Path(__file__).parent / "report_template.html"
        if not template_path.exists():
            print(f"Template not found: {template_path}", file=sys.stderr)
            sys.exit(1)

        with open(template_path) as f:
            template = Template(f.read())

        # Prepare template data
        start_dt = datetime.fromtimestamp(self.config.start_time)
        end_dt = datetime.fromtimestamp(self.config.end_time)
        duration_min = self.config.duration_seconds / 60

        # Parse sysbench output and configmap if available
        sysbench_output_path = Path(self.config.output_dir).parent / "output" / "sysbench" / "sysbench_output.txt"
        sysbench_results = parse_sysbench_output(sysbench_output_path)

        # Get sysbench params from live configmap
        sysbench_params = self._get_sysbench_params()

        # Enrich sysbench intervals with per-interval Prometheus samples (CPU/mem/net/disk).
        if sysbench_results and sysbench_results.get("intervals"):
            interval_step = 10
            if sysbench_params and sysbench_params.get("report-interval"):
                try:
                    interval_step = int(sysbench_params["report-interval"])
                except ValueError:
                    pass
            elif len(sysbench_results["intervals"]) >= 2:
                # Fall back to the spacing sysbench actually reported
                t0 = sysbench_results["intervals"][0]["time"]
                t1 = sysbench_results["intervals"][1]["time"]
                if t1 > t0:
                    interval_step = t1 - t0
            print(f"Enriching {len(sysbench_results['intervals'])} sysbench intervals with Prometheus metrics (step={interval_step}s)...")
            sysbench_results["intervals"] = self.enrich_intervals_with_metrics(
                sysbench_results["intervals"], interval_step
            )

        report_data = {
            "title": self.config.title,
            "start_time": start_dt.strftime("%Y-%m-%d %H:%M:%S"),
            "end_time": end_dt.strftime("%Y-%m-%d %H:%M:%S"),
            "duration": f"{duration_min:.1f} minutes",
            "start_epoch": int(self.config.start_time),
            "end_epoch": int(self.config.end_time),
            "warmup_end_epoch": int(self.config.warmup_end) if self.config.warmup_end else None,
            "pods": self.config.pods,
            "metrics": self.metrics_data,
            "by_pod": self.by_pod,
            "by_node": self.by_node,
            "pod_to_node": self.pod_to_node,
            "cluster_spec": self.cluster_spec,
            "sysbench_results": sysbench_results,
            "sysbench_params": sysbench_params,
            "format_number": format_number,
        }

        return template.render(**report_data)

    def save_report(self, html_content: str):
        """Save report to file."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M")
        output_dir = Path(self.config.output_dir) / timestamp
        output_dir.mkdir(parents=True, exist_ok=True)

        output_file = output_dir / "report.html"
        with open(output_file, "w") as f:
            f.write(html_content)

        print(f"Report saved to: {output_file}")

        # Copy sysbench output file(s)
        sysbench_dir = Path(self.config.output_dir).parent / "output" / "sysbench"
        sysbench_output = sysbench_dir / "sysbench_output.txt"
        if sysbench_output.exists():
            shutil.copy(sysbench_output, output_dir / "sysbench_output.txt")
            print(f"Copied sysbench output to: {output_dir / 'sysbench_output.txt'}")
        for pod_file in sorted(sysbench_dir.glob("sysbench_output_*.txt")):
            shutil.copy(pod_file, output_dir / pod_file.name)
            print(f"Copied per-pod output: {pod_file.name}")

        # Copy node spec files if they exist
        node_spec = Path(self.config.output_dir).parent / "output" / "sysbench" / "RUN_NODE_SPEC.txt"
        if node_spec.exists():
            shutil.copy(node_spec, output_dir / "RUN_NODE_SPEC.txt")
            print(f"Copied node spec to: {output_dir / 'RUN_NODE_SPEC.txt'}")
        sysbench_spec = Path(self.config.output_dir).parent / "output" / "sysbench" / "SYSBENCH_NODE_SPEC.txt"
        if sysbench_spec.exists():
            shutil.copy(sysbench_spec, output_dir / "SYSBENCH_NODE_SPEC.txt")
            print(f"Copied sysbench node spec to: {output_dir / 'SYSBENCH_NODE_SPEC.txt'}")

        # Copy sysbench_times.txt so report-parser.py can read WARMUP_END_TIME
        times_file = Path(self.config.output_dir).parent / "output" / "sysbench" / "sysbench_times.txt"
        if times_file.exists():
            shutil.copy(times_file, output_dir / "sysbench_times.txt")
            print(f"Copied timestamps to: {output_dir / 'sysbench_times.txt'}")

        # Save sysbench configmap (contains rendered parameters)
        self._save_sysbench_configmap(output_dir)

        return output_file

    def _get_sysbench_params(self) -> Optional[dict]:
        """Get sysbench parameters from the live configmap."""
        configmap_name = f"{self.config.release_name}-sysbench-scripts"
        cmd = [
            "kubectl", "--context", self.config.kube_context,
            "-n", self.config.namespace,
            "get", "configmap", configmap_name,
            "-o", "yaml"
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                # Write to a temp path and parse
                import tempfile
                with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
                    f.write(result.stdout)
                    tmp_path = Path(f.name)
                params = parse_sysbench_configmap(tmp_path)
                tmp_path.unlink()
                return params
        except Exception:
            pass
        return None

    def _save_sysbench_configmap(self, output_dir: Path):
        """Save the sysbench scripts configmap to capture exact parameters used."""
        configmap_name = f"{self.config.release_name}-sysbench-scripts"
        cmd = [
            "kubectl", "--context", self.config.kube_context,
            "-n", self.config.namespace,
            "get", "configmap", configmap_name,
            "-o", "yaml"
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                configmap_file = output_dir / "sysbench-configmap.yaml"
                with open(configmap_file, "w") as f:
                    f.write(result.stdout)
                print(f"Saved sysbench configmap to: {configmap_file}")
            else:
                print(f"Warning: Could not get sysbench configmap: {result.stderr}", file=sys.stderr)
        except Exception as e:
            print(f"Warning: Failed to save sysbench configmap: {e}", file=sys.stderr)


def parse_sysbench_output(filepath: Path) -> Optional[dict]:
    """Parse sysbench_output.txt and extract results."""
    if not filepath.exists():
        return None

    text = filepath.read_text()
    result = {}

    # Parse interval reports: [ 10s ] thds: 24 tps: 98.19 qps: 3372.21 (r/w/o: 997.53/2176.67/198.01) lat (ms,95%): 297.92 err/s: 1.02 reconn/s: 0.00
    intervals = []
    for m in re.finditer(
        r'\[\s*(\d+)s\s*\]\s*thds:\s*(\d+)\s*tps:\s*([\d.]+)\s*qps:\s*([\d.]+)\s*'
        r'\(r/w/o:\s*([\d.]+)/([\d.]+)/([\d.]+)\)\s*lat\s*\(ms,95%\):\s*([\d.]+)\s*'
        r'err/s:\s*([\d.]+)',
        text
    ):
        intervals.append({
            "time": int(m.group(1)),
            "threads": int(m.group(2)),
            "tps": float(m.group(3)),
            "qps": float(m.group(4)),
            "read_qps": float(m.group(5)),
            "write_qps": float(m.group(6)),
            "other_qps": float(m.group(7)),
            "lat_95": float(m.group(8)),
            "err_s": float(m.group(9)),
        })
    result["intervals"] = intervals

    # Parse SQL statistics
    sql_stats = {}
    for key in ["read", "write", "other", "total"]:
        m = re.search(rf'^\s*{key}:\s+(\d+)', text, re.MULTILINE)
        if m:
            sql_stats[key] = int(m.group(1))
    result["sql_stats"] = sql_stats

    # Parse summary stats
    m = re.search(r'transactions:\s+(\d+)\s+\(([\d.]+) per sec\.\)', text)
    if m:
        result["transactions"] = int(m.group(1))
        result["tps"] = float(m.group(2))

    m = re.search(r'queries:\s+(\d+)\s+\(([\d.]+) per sec\.\)', text)
    if m:
        result["queries"] = int(m.group(1))
        result["qps"] = float(m.group(2))

    m = re.search(r'ignored errors:\s+(\d+)\s+\(([\d.]+) per sec\.\)', text)
    if m:
        result["errors"] = int(m.group(1))
        result["errors_per_sec"] = float(m.group(2))

    # Latency
    for key, label in [("min", "min"), ("avg", "avg"), ("max", "max"), ("95th percentile", "p95")]:
        m = re.search(rf'^\s*{re.escape(key)}:\s+([\d.]+)', text, re.MULTILINE)
        if m:
            result[f"lat_{label}"] = float(m.group(1))

    # Thread fairness
    m = re.search(r'events \(avg/stddev\):\s+([\d.]+)/([\d.]+)', text)
    if m:
        result["fairness_avg"] = float(m.group(1))
        result["fairness_stddev"] = float(m.group(2))

    m = re.search(r'time elapsed:\s+([\d.]+)', text)
    if m:
        result["elapsed"] = float(m.group(1))

    return result


def parse_sysbench_configmap(filepath: Path) -> Optional[dict]:
    """Parse sysbench-configmap.yaml and extract run parameters."""
    if not filepath.exists():
        return None

    text = filepath.read_text()

    # Extract sysbench-run.sh section and parse flags
    params = {}
    in_run_script = False
    for line in text.split('\n'):
        if 'sysbench-run.sh' in line:
            in_run_script = True
            continue
        if in_run_script:
            if line.strip().startswith('sysbench-') and line.strip().endswith('.sh: |'):
                break  # next script section
            m = re.match(r'\s*--(\S+?)(?:=(.+?))?\s*\\?\s*$', line)
            if m:
                key = m.group(1)
                val = (m.group(2) or "true").rstrip(' \\')
                params[key] = val
            # Also capture the workload name (e.g. "exec sysbench oltp_read_write")
            m2 = re.match(r'\s*exec sysbench\s+(\S+)', line)
            if m2:
                params["workload"] = m2.group(1)

    # Remove sensitive parameters
    sensitive_keys = {"pgsql-user", "pgsql-password", "pgsql-host", "pgsql-port", "db-driver"}
    for k in sensitive_keys:
        params.pop(k, None)

    return params if params else None


def format_number(value: float, suffix: str = "") -> str:
    """Format large numbers with K/M/B suffixes."""
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.2f}B{suffix}"
    elif value >= 1_000_000:
        return f"{value / 1_000_000:.2f}M{suffix}"
    elif value >= 1_000:
        return f"{value / 1_000:.2f}K{suffix}"
    else:
        return f"{value:.2f}{suffix}"


def main():
    parser = argparse.ArgumentParser(description="Generate stress test report from Prometheus metrics")
    parser.add_argument("--start", type=float, required=True, help="Start timestamp (Unix)")
    parser.add_argument("--end", type=float, required=True, help="End timestamp (Unix)")
    parser.add_argument("--warmup-end", type=float, default=None,
                        help="Warmup end timestamp (Unix); shaded on charts if set")
    parser.add_argument("--step", type=int, default=30, help="Query step in seconds (default: 30)")
    parser.add_argument("--kube-context", default="minikube", help="Kubernetes context")
    parser.add_argument("--namespace", default="yugabyte-test", help="Kubernetes namespace")
    parser.add_argument("--release-name", default="yb-bench", help="Helm release name")
    parser.add_argument("--prometheus-url", default="http://yb-bench-prometheus:9090", help="Prometheus URL (inside cluster)")
    parser.add_argument("--pods", nargs="+", default=["yb-tserver.*", "yb-master.*", "sysbench.*"],
                        help="Pod name patterns to monitor")
    parser.add_argument("--rate-of", action="append", dest="rate_metrics", default=[],
                        help="Rate metric expression (can be repeated)")
    parser.add_argument("--total-of", action="append", dest="total_metrics", default=[],
                        help="Total metric expression (can be repeated)")
    parser.add_argument("--title", default="Sysbench Stress Test Report", help="Report title")
    parser.add_argument("--output-dir", default="reports", help="Output directory")

    args = parser.parse_args()

    config = ReportConfig(
        start_time=args.start,
        end_time=args.end,
        warmup_end=args.warmup_end,
        step=args.step,
        kube_context=args.kube_context,
        namespace=args.namespace,
        release_name=args.release_name,
        prometheus_url=args.prometheus_url,
        pods=args.pods,
        rate_metrics=args.rate_metrics,
        total_metrics=args.total_metrics,
        title=args.title,
        output_dir=args.output_dir,
    )

    generator = ReportGenerator(config)
    generator.validate_connectivity()
    html = generator.generate_report()
    generator.save_report(html)


if __name__ == "__main__":
    main()
