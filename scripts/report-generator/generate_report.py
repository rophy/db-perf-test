#!/usr/bin/env python3
"""
Stress Test Report Generator for YugabyteDB Sysbench Benchmarks

Generates HTML reports with Chart.js visualizations from Prometheus metrics.
"""

import argparse
import json
import os
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
    metrics_dump_base_url: str = ""
    workload_type: str = "sysbench"

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


    def exec_pod_curl(self, pod: str, container: str, url: str) -> Optional[str]:
        """Execute curl inside a specific pod (YB pods have curl, not wget)."""
        cmd = [
            "kubectl", "--context", self.kube_context,
            "exec", "-n", self.namespace, pod, "-c", container,
            "--", "curl", "-s", url
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                return result.stdout
            return None
        except Exception:
            return None


class PrometheusClient:
    """Client for querying Prometheus metrics."""

    def __init__(self, executor: QueryExecutor, base_url: str):
        self.executor = executor
        self.base_url = base_url

    def label_values(self, label: str, match: str = "") -> list[str]:
        """Fetch distinct values for a label, optionally filtered by match[]."""
        url = f"{self.base_url}/api/v1/label/{label}/values"
        if match:
            url += f"?match[]={quote(match)}"
        response = self.executor.exec_curl(url)
        if not response:
            return []
        try:
            data = json.loads(response)
            if data.get("status") == "success":
                return data.get("data", [])
        except json.JSONDecodeError:
            pass
        return []

    def targets_metadata(self, match_target: str, limit: int = 5000) -> dict[str, str]:
        """Fetch metric type annotations via /api/v1/targets/metadata."""
        qs = f"match_target={quote(match_target)}&limit={limit}"
        url = f"{self.base_url}/api/v1/targets/metadata?{qs}"
        response = self.executor.exec_curl(url)
        if not response:
            return {}
        try:
            data = json.loads(response)
            if data.get("status") != "success":
                return {}
            types: dict[str, str] = {}
            for m in data.get("data", []):
                types[m["metric"]] = m["type"]
            return types
        except (json.JSONDecodeError, KeyError):
            return {}

    def query_range_raw(self, query: str, start: float, end: float, step: int) -> list[dict]:
        """Execute a range query and return raw result dicts (metric + values)."""
        encoded_query = quote(query)
        url = f"{self.base_url}/api/v1/query_range?query={encoded_query}&start={start}&end={end}&step={step}"
        response = self.executor.exec_curl(url)
        if not response:
            return []
        try:
            data = json.loads(response)
            if data.get("status") != "success":
                return []
            return data.get("data", {}).get("result", [])
        except json.JSONDecodeError:
            return []

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
        self._node_instance_filter = ""
        self._tserver_instance_filter = ""

    def _derive_node_instances(self):
        """Extract node hostnames from container metrics and build instance filters.

        Must be called after collect_container_metrics(). Scans the CPU series
        (which are namespace-filtered) for distinct instance values.

        Builds two filters:
        - _node_instance_filter: all nodes hosting any pod in the namespace
        - _tserver_instance_filter: only nodes hosting yb-tserver pods
        """
        cpu_data = self.metrics_data.get("cpu", {})
        all_instances = set()
        tserver_instances = set()
        for s in cpu_data.get("series", []):
            inst = s.get("instance")
            if not inst:
                continue
            all_instances.add(inst)
            pod = s.get("name", "")
            if pod.startswith("yb-tserver"):
                tserver_instances.add(inst)

        for label, instances in [("all", all_instances), ("tserver", tserver_instances)]:
            insts = sorted(instances)
            if insts:
                regex = "|".join(insts)
                filt = f'instance=~"{regex}"'
                print(f"  {label} instance filter: {len(insts)} nodes ({', '.join(insts)})")
            else:
                filt = ""
                print(f"  Warning: no {label} instances found from container metrics", file=sys.stderr)
            if label == "all":
                self._node_instance_filter = filt
            else:
                self._tserver_instance_filter = filt

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

    # (pod_regex, container_label_match) for each role we chart. Each role
    # queries the pod's MAIN container only (yb-tserver pods → container=
    # "yb-tserver", yb-master pods → container="yb-master"). Sidecars
    # (yb-cleanup, yugabyted-ui), pod-cgroup row, and pause container are
    # implicitly excluded by the positive container match.
    #
    # Why per-role + positive match instead of negative-filter sum across
    # containers: when one container's irate window contains only 1 raw
    # sample, Prometheus drops its irate to null. sum() across the rest then
    # leaves only tiny sidecar values, producing false-zero dips on the chart
    # (the original Issue #2 symptom resurfaced for one container's bad luck).
    # Positive single-container match is either present or absent — never
    # artificially small.
    _ROLE_QUERIES = (
        ("yb-tserver.*", 'container="yb-tserver"'),
        ("yb-master.*",  'container="yb-master"'),
    )

    # Prometheus query_range step per metric source. Each step is matched
    # to its source's natural sample cadence — denser steps just plateau,
    # sparser steps lose detail.
    #
    # cAdvisor refreshes internally every ~10-15s regardless of Prometheus
    # scrape_interval, so step=10 yields one fresh value per cAdvisor cycle
    # plus ~one repeat plateau per ~15s gap. step=5 here would add no real
    # information (just more plateaus), and step >=15 risks dropping points
    # at irate-window edges where only one raw sample falls in [t-30, t].
    _CADVISOR_STEP = 10
    # node_exporter is updated on every Prometheus scrape (5s in this chart),
    # so each step=5 evaluation point gives a genuinely new value. Going to
    # step=10 would throw away half the resolution for no reason.
    _NODE_STEP = 5

    def collect_container_metrics(self):
        """Collect CPU, memory, network, disk metrics for pods."""
        ns = self.config.namespace

        # Window for cAdvisor-sourced rates. cAdvisor refreshes its counters
        # internally only every ~10-15s regardless of Prometheus scrape_interval,
        # so a 15s window often captures fewer than 2 distinct raw samples and
        # irate returns no value. 30s reliably spans 2+ refreshes.
        cadvisor_window = "30s"

        # Build the union of per-role queries via PromQL `or`. Label sets
        # (instance, pod) never overlap between roles, so `or` gives a clean
        # union without dedup surprises.
        def union(make_one):
            return " or ".join(make_one(pods, cf) for pods, cf in self._ROLE_QUERIES)

        # Pod-level metrics with no container labels (network, shared netns).
        net_pods_regex = "|".join(p for p, _ in self._ROLE_QUERIES)

        # CPU usage (cores).
        cpu_query = union(lambda pods, cf: (
            f'sum by (instance, pod) ('
            f'irate(container_cpu_usage_seconds_total{{namespace="{ns}",'
            f'pod=~"{pods}",{cf}}}[{cadvisor_window}]))'
        ))
        self.metrics_data["cpu"] = self._query_and_aggregate(cpu_query, "CPU Usage (cores)", step=self._CADVISOR_STEP)

        # Memory usage (MB) — gauge, no rate.
        mem_query = union(lambda pods, cf: (
            f'sum by (instance, pod) ('
            f'container_memory_working_set_bytes{{namespace="{ns}",'
            f'pod=~"{pods}",{cf}}}) / 1024 / 1024'
        ))
        self.metrics_data["memory"] = self._query_and_aggregate(mem_query, "Memory Usage (MB)", step=self._CADVISOR_STEP)

        # Network RX/TX (MB/s) — cAdvisor only emits pod-level rows for these
        # (shared netns), so no container filter is needed. Unit matches
        # memory (MB) for consistent axes across pod cards.
        net_rx_query = (
            f'sum by (instance, pod) ('
            f'irate(container_network_receive_bytes_total{{namespace="{ns}",'
            f'pod=~"{net_pods_regex}"}}[{cadvisor_window}])) / 1024 / 1024'
        )
        self.metrics_data["network_rx"] = self._query_and_aggregate(net_rx_query, "Network RX (MB/s)", step=self._CADVISOR_STEP)

        net_tx_query = (
            f'sum by (instance, pod) ('
            f'irate(container_network_transmit_bytes_total{{namespace="{ns}",'
            f'pod=~"{net_pods_regex}"}}[{cadvisor_window}])) / 1024 / 1024'
        )
        self.metrics_data["network_tx"] = self._query_and_aggregate(net_tx_query, "Network TX (MB/s)", step=self._CADVISOR_STEP)

        # Disk Read/Write IOPS and Throughput — same per-role split as CPU.
        disk_read_iops_query = union(lambda pods, cf: (
            f'sum by (instance, pod) ('
            f'irate(container_fs_reads_total{{namespace="{ns}",'
            f'pod=~"{pods}",{cf}}}[{cadvisor_window}]))'
        ))
        self.metrics_data["disk_read_iops"] = self._query_and_aggregate(disk_read_iops_query, "Disk Read IOPS", step=self._CADVISOR_STEP)

        disk_write_iops_query = union(lambda pods, cf: (
            f'sum by (instance, pod) ('
            f'irate(container_fs_writes_total{{namespace="{ns}",'
            f'pod=~"{pods}",{cf}}}[{cadvisor_window}]))'
        ))
        self.metrics_data["disk_write_iops"] = self._query_and_aggregate(disk_write_iops_query, "Disk Write IOPS", step=self._CADVISOR_STEP)

        disk_read_throughput_query = union(lambda pods, cf: (
            f'sum by (instance, pod) ('
            f'irate(container_fs_reads_bytes_total{{namespace="{ns}",'
            f'pod=~"{pods}",{cf}}}[{cadvisor_window}])) / 1024 / 1024'
        ))
        self.metrics_data["disk_read_throughput"] = self._query_and_aggregate(disk_read_throughput_query, "Disk Read (MB/s)", step=self._CADVISOR_STEP)

        disk_write_throughput_query = union(lambda pods, cf: (
            f'sum by (instance, pod) ('
            f'irate(container_fs_writes_bytes_total{{namespace="{ns}",'
            f'pod=~"{pods}",{cf}}}[{cadvisor_window}])) / 1024 / 1024'
        ))
        self.metrics_data["disk_write_throughput"] = self._query_and_aggregate(disk_write_throughput_query, "Disk Write (MB/s)", step=self._CADVISOR_STEP)

    def collect_node_metrics(self):
        """Collect node-level CPU/memory/network/disk from node_exporter.

        Filtered to only nodes hosting pods in the YB namespace (via
        _node_instance_filter derived from container metrics).
        """
        nf = self._node_instance_filter
        nf_comma = f",{nf}" if nf else ""

        # Node CPU in cores-used, per instance.
        #   count-by-instance of idle rows  = total CPUs on that node
        #   sum-by-instance of irate(idle)  = idle cores
        #   difference                      = cores in use
        # Reported in cores so it overlays 1:1 with container CPU (also cores).
        node_cpu_query = (
            f'(count by (instance) (node_cpu_seconds_total{{mode="idle"{nf_comma}}})) '
            f'- sum by (instance) (irate(node_cpu_seconds_total{{mode="idle"{nf_comma}}}[15s]))'
        )
        self.metrics_data["node_cpu"] = self._query_and_aggregate_by_instance(
            node_cpu_query, "Node CPU Total (cores)", step=self._NODE_STEP)

        # CPU breakdown by mode (kept as percent — informational detail charts).
        for mode in ["user", "system", "iowait", "steal", "softirq"]:
            query = f'avg by (instance) (irate(node_cpu_seconds_total{{mode="{mode}"{nf_comma}}}[15s])) * 100'
            self.metrics_data[f"node_cpu_{mode}"] = self._query_and_aggregate_by_instance(
                query, f"Node CPU {mode} (%)", step=self._NODE_STEP)

        # Node memory used (MB) = MemTotal - MemAvailable.
        node_mem_query = (
            f'(node_memory_MemTotal_bytes{{{nf}}} - node_memory_MemAvailable_bytes{{{nf}}}) / 1024 / 1024'
        )
        self.metrics_data["node_memory"] = self._query_and_aggregate_by_instance(
            node_mem_query, "Node Memory Used (MB)", step=self._NODE_STEP)

        # Node network RX/TX — pick the BUSIEST non-loopback interface per node.
        # Can't sum here: on K8s, CNI plugins mirror pod traffic across multiple
        # virtual interfaces (flannel.1, cni0, vethXX, ...) so summing counts
        # the same bytes 3-4× (seen: 4× over-count on k3s-virsh). A filter-list
        # of virtual-interface names is fragile (new CNIs, multi-ENI on EKS).
        # max() reports the hottest interface, which is either the physical NIC
        # (single-NIC + mirrors) or the busiest ENI (multi-NIC) — both are
        # meaningful ceilings for "how loaded is the node's network path".
        # Underreports in the rare case of balanced multi-NIC traffic.
        self.metrics_data["node_network_rx"] = self._query_and_aggregate_by_instance(
            f'max by (instance) (irate(node_network_receive_bytes_total{{device!="lo"{nf_comma}}}[15s])) / 1024 / 1024',
            "Node Network RX (MB/s)", step=self._NODE_STEP,
        )
        self.metrics_data["node_network_tx"] = self._query_and_aggregate_by_instance(
            f'max by (instance) (irate(node_network_transmit_bytes_total{{device!="lo"{nf_comma}}}[15s])) / 1024 / 1024',
            "Node Network TX (MB/s)", step=self._NODE_STEP,
        )

        # Node disk I/O summed across devices. Exclude loop/dm devices to focus
        # on physical disks; wrapped in sum-by-instance so a node with multiple
        # devices still returns one series per instance.
        disk_filter = f'device!~"loop.*|dm-.*"{nf_comma}'
        self.metrics_data["node_disk_read_iops"] = self._query_and_aggregate_by_instance(
            f'sum by (instance) (irate(node_disk_reads_completed_total{{{disk_filter}}}[15s]))',
            "Node Disk Read IOPS", step=self._NODE_STEP,
        )
        self.metrics_data["node_disk_write_iops"] = self._query_and_aggregate_by_instance(
            f'sum by (instance) (irate(node_disk_writes_completed_total{{{disk_filter}}}[15s]))',
            "Node Disk Write IOPS", step=self._NODE_STEP,
        )
        self.metrics_data["node_disk_read_throughput"] = self._query_and_aggregate_by_instance(
            f'sum by (instance) (irate(node_disk_read_bytes_total{{{disk_filter}}}[15s])) / 1024 / 1024',
            "Node Disk Read (MB/s)", step=self._NODE_STEP,
        )
        self.metrics_data["node_disk_write_throughput"] = self._query_and_aggregate_by_instance(
            f'sum by (instance) (irate(node_disk_written_bytes_total{{{disk_filter}}}[15s])) / 1024 / 1024',
            "Node Disk Write (MB/s)", step=self._NODE_STEP,
        )

    def _query_and_aggregate_by_instance(self, query: str, display_name: str,
                                         step: Optional[int] = None) -> dict:
        """Query metrics and aggregate results, grouped by instance (node)."""
        series_list = self.prometheus.query_range(
            query,
            self.config.start_time,
            self.config.end_time,
            step if step is not None else self.config.step
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
        # Main t-server container only (see _ROLE_QUERIES rationale).
        tserver_container = 'container="yb-tserver"'
        # node_cpu_seconds_total refreshes every scrape (5s); cAdvisor refreshes
        # every ~10-15s so its rate windows must be wider. See collect_container_metrics.
        node_window = "15s"
        cadvisor_window = "30s"

        tf = self._tserver_instance_filter
        tf_comma = f",{tf}" if tf else ""

        queries = {
            # DB-node VM CPU in cores-used, averaged across tserver nodes only.
            "cpu_cores": (
                'avg('
                f'count by (instance) (node_cpu_seconds_total{{mode="idle"{tf_comma}}}) '
                f'- sum by (instance) (irate(node_cpu_seconds_total{{mode="idle"{tf_comma}}}[{node_window}])))'
            ),
            # Total tserver-container memory in MB (sum of per-container rows).
            "mem_mb": (
                f'sum(container_memory_working_set_bytes{{namespace="{ns}",'
                f'pod=~"{tserver_regex}",{tserver_container}}}) / 1024 / 1024'
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
                f'pod=~"{tserver_regex}",{tserver_container}}}[{cadvisor_window}]))'
            ),
            # Client pod CPU in cores consumed, summed across replicas.
            "client_cpu_cores": (
                f'sum(irate(container_cpu_usage_seconds_total{{namespace="{ns}",'
                f'pod=~".*k6.*",container="k6"}}[{cadvisor_window}]))'
                if self.config.workload_type == "k6" else
                f'sum(irate(container_cpu_usage_seconds_total{{namespace="{ns}",'
                f'pod=~".*sysbench.*",container="sysbench"}}[{cadvisor_window}]))'
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

    def _query_and_aggregate(self, query: str, display_name: str,
                             step: Optional[int] = None) -> dict:
        """Query metrics and aggregate results."""
        series_list = self.prometheus.query_range(
            query,
            self.config.start_time,
            self.config.end_time,
            step if step is not None else self.config.step
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

    _YB_DUMP_STEP = 5
    _YB_DUMP_BATCH_SIZE = 50
    _YB_IRATE_WINDOW = "15s"

    def _fetch_yb_metric_types(self) -> dict[str, str]:
        """Fetch metric TYPE annotations from YB tserver and master endpoints."""
        types: dict[str, str] = {}
        endpoints = [
            ("yb-tserver-0", "yb-tserver", "http://localhost:9000/prometheus-metrics"),
            ("yb-master-0", "yb-master", "http://localhost:7000/prometheus-metrics"),
        ]
        for pod, container, url in endpoints:
            output = self.executor.exec_pod_curl(pod, container, url)
            if not output:
                continue
            for line in output.split("\n"):
                if line.startswith("# TYPE "):
                    parts = line.split()
                    if len(parts) >= 4:
                        types[parts[2]] = parts[3]
        return types

    def collect_yb_metrics_dump(self) -> list[dict]:
        """Dump all YugabyteDB metrics for the run window with meaningful PromQL.

        Counters are queried as irate() rates, gauges as raw values.
        Per-tablet/table metrics are pre-aggregated to per-instance with sum by.

        Prometheus doesn't support irate() with __name__ regex selectors,
        so counters are queried one metric at a time. Gauges can be batched.
        """
        metric_types = self._fetch_yb_metric_types()
        print(f"Fetched {len(metric_types)} YB metric type annotations "
              f"({sum(1 for v in metric_types.values() if v == 'counter')} counters, "
              f"{sum(1 for v in metric_types.values() if v == 'gauge')} gauges)")

        names = self.prometheus.label_values(
            "__name__", '{job=~"yb-tserver|yb-master"}'
        )
        if not names:
            print("Warning: no YB metric names found", file=sys.stderr)
            return []

        # Skip _bucket metrics (histogram detail not useful in explorer).
        names = [n for n in names if not n.endswith("_bucket")]

        counters = []
        gauges = []
        for n in names:
            base = re.sub(r"_(count|sum)$", "", n)
            mtype = metric_types.get(n) or metric_types.get(base, "counter")
            if mtype == "gauge":
                gauges.append(n)
            else:
                counters.append(n)

        print(f"Querying {len(counters)} counters (irate, parallel) + "
              f"{len(gauges)} gauges ({self._YB_DUMP_BATCH_SIZE}/batch)...")

        all_series: list[dict] = []

        # Counters: irate per metric (Prometheus rejects irate with __name__ regex).
        # Parallelized with ThreadPoolExecutor since each kubectl exec is I/O-bound.
        print("  Counters (irate, sum by instance):")
        from concurrent.futures import ThreadPoolExecutor, as_completed

        def _query_counter(name: str) -> list[dict]:
            query = (
                f'sum by (exported_instance)'
                f'(irate({name}{{job=~"yb-tserver|yb-master"}}[{self._YB_IRATE_WINDOW}]))'
            )
            results = self.prometheus.query_range_raw(
                query, self.config.start_time, self.config.end_time,
                self._YB_DUMP_STEP,
            )
            for r in results:
                r.setdefault("metric", {})["__name__"] = name
            return results

        done_count = 0
        with ThreadPoolExecutor(max_workers=16) as pool:
            futures = {pool.submit(_query_counter, n): n for n in counters}
            for future in as_completed(futures):
                results = future.result()
                all_series.extend(results)
                done_count += 1
                if done_count % 200 == 0 or done_count == len(counters):
                    print(f"    {done_count}/{len(counters)}, {len(all_series)} series total")

        # Gauges: can batch via __name__ regex.
        print("  Gauges (raw, sum by instance):")
        for i in range(0, len(gauges), self._YB_DUMP_BATCH_SIZE):
            batch = gauges[i:i + self._YB_DUMP_BATCH_SIZE]
            regex = "|".join(batch)
            query = (
                f'sum by (__name__, exported_instance)'
                f'({{__name__=~"{regex}",job=~"yb-tserver|yb-master"}})'
            )
            results = self.prometheus.query_range_raw(
                query, self.config.start_time, self.config.end_time,
                self._YB_DUMP_STEP,
            )
            all_series.extend(results)
            done = min(i + self._YB_DUMP_BATCH_SIZE, len(gauges))
            if (i // self._YB_DUMP_BATCH_SIZE) % 10 == 0 or done == len(gauges):
                print(f"    {done}/{len(gauges)}, {len(all_series)} series total")

        return all_series

    _NODE_DUMP_STEP = 5
    _NODE_IRATE_WINDOW = "15s"
    _NODE_BATCH_SIZE = 50

    def collect_node_metrics_dump(self) -> list[dict]:
        """Dump all node_exporter metrics, pre-aggregated per instance.

        Same approach as collect_yb_metrics_dump: counters as irate() rates,
        gauges as raw values, aggregated with sum by (instance).
        Filtered to only nodes hosting YB pods (via _node_instance_filter).
        Output is normalized to use exported_instance key so the Metrics
        Explorer JS works without changes.
        """
        type_map = self.prometheus.targets_metadata('{job="node-exporter"}')
        if not type_map:
            print("Warning: no node-exporter metadata found", file=sys.stderr)
            return []

        names = self.prometheus.label_values(
            "__name__", '{job="node-exporter"}'
        )
        if not names:
            print("Warning: no node-exporter metric names found", file=sys.stderr)
            return []

        names = [n for n in names if not n.endswith("_bucket")]

        counters = []
        gauges = []
        for n in names:
            t = type_map.get(n, "")
            if t == "counter" or n.endswith("_total"):
                counters.append(n)
            else:
                gauges.append(n)

        nf = self._node_instance_filter
        nf_comma = f",{nf}" if nf else ""

        print(f"  {len(counters)} counters + {len(gauges)} gauges "
              f"({len(names)} names, {len(type_map)} metadata entries)")

        all_series: list[dict] = []

        from concurrent.futures import ThreadPoolExecutor, as_completed

        def _query_counter(name: str) -> list[dict]:
            query = (
                f'sum by (instance)'
                f'(irate({name}{{job="node-exporter"{nf_comma}}}[{self._NODE_IRATE_WINDOW}]))'
            )
            results = self.prometheus.query_range_raw(
                query, self.config.start_time, self.config.end_time,
                self._NODE_DUMP_STEP,
            )
            for r in results:
                r.setdefault("metric", {})["__name__"] = name
            return results

        print("  Counters (irate, sum by instance):")
        done_count = 0
        with ThreadPoolExecutor(max_workers=16) as pool:
            futures = {pool.submit(_query_counter, n): n for n in counters}
            for future in as_completed(futures):
                all_series.extend(future.result())
                done_count += 1
                if done_count % 50 == 0 or done_count == len(counters):
                    print(f"    {done_count}/{len(counters)}, {len(all_series)} series total")

        print("  Gauges (raw, sum by instance):")
        for i in range(0, len(gauges), self._NODE_BATCH_SIZE):
            batch = gauges[i:i + self._NODE_BATCH_SIZE]
            regex = "|".join(batch)
            query = (
                f'sum by (__name__, instance)'
                f'({{__name__=~"{regex}",job="node-exporter"{nf_comma}}})'
            )
            results = self.prometheus.query_range_raw(
                query, self.config.start_time, self.config.end_time,
                self._NODE_DUMP_STEP,
            )
            all_series.extend(results)
            done = min(i + self._NODE_BATCH_SIZE, len(gauges))
            if (i // self._NODE_BATCH_SIZE) % 5 == 0 or done == len(gauges):
                print(f"    {done}/{len(gauges)}, {len(all_series)} series total")

        # Normalize: rename "instance" to "exported_instance" so the
        # Metrics Explorer JS handles node and YB metrics uniformly.
        for s in all_series:
            m = s.get("metric", {})
            if "instance" in m and "exported_instance" not in m:
                m["exported_instance"] = m.pop("instance")

        return all_series

    def collect_k6_metrics_dump(self) -> list[dict]:
        """Dump all k6 metrics pushed via Prometheus remote write.

        Counters (_total suffix) as irate() rates, everything else as raw values.
        k6 pushes every 5s by default, so we use step=5.
        """
        names = self.prometheus.label_values(
            "__name__", '{__name__=~"k6_.*"}'
        )
        if not names:
            print("  No k6 metrics found, skipping")
            return []

        counters = [n for n in names if n.endswith("_total")]
        gauges = [n for n in names if not n.endswith("_total")]

        print(f"  {len(counters)} counters + {len(gauges)} gauges ({len(names)} names)")

        all_series: list[dict] = []
        step = 5

        for name in counters:
            query = f'irate({name}[30s])'
            results = self.prometheus.query_range_raw(
                query, self.config.start_time, self.config.end_time, step,
            )
            for r in results:
                r.setdefault("metric", {})["__name__"] = name
            all_series.extend(results)

        for name in gauges:
            results = self.prometheus.query_range_raw(
                name, self.config.start_time, self.config.end_time, step,
            )
            all_series.extend(results)

        print(f"  {len(all_series)} series total")
        return all_series

    @staticmethod
    def build_metrics_index(dump: list[dict]) -> list[dict]:
        """Build a summary index of metric names for the explorer picker."""
        name_info: dict[str, dict] = {}
        for s in dump:
            m = s.get("metric", {})
            name = m.get("__name__", "")
            if name not in name_info:
                name_info[name] = {
                    "name": name,
                    "count": 0,
                }
            name_info[name]["count"] += 1
        return sorted(name_info.values(), key=lambda x: x["name"])

    def generate_report(self) -> str:
        """Generate HTML report."""
        # Collect cluster specifications
        self.cluster_spec = self.cluster_collector.collect()

        # Collect metrics
        print("Collecting container metrics...")
        self.collect_container_metrics()

        print("Deriving node instance filter from container metrics...")
        self._derive_node_instances()

        print("Collecting node metrics...")
        self.collect_node_metrics()

        print("Collecting custom metrics...")
        self.collect_custom_metrics()

        # Dump all YB + node + k6 metrics for the Metrics Explorer tab.
        print("Collecting YB metrics dump...")
        self.yb_dump = self.collect_yb_metrics_dump()
        print("Collecting node-exporter metrics dump...")
        self.yb_dump.extend(self.collect_node_metrics_dump())
        if self.config.workload_type == "k6":
            print("Collecting k6 metrics dump...")
            self.yb_dump.extend(self.collect_k6_metrics_dump())
        self.yb_metrics_index = self.build_metrics_index(self.yb_dump)

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

        # Parse workload results based on type
        if self.config.workload_type == "k6":
            workload_name = "k6"
            latency_percentile = "p95"
            print("Collecting k6 results from Prometheus...")
            sysbench_results = self.collect_k6_results_from_prometheus(step=10)
            sysbench_params = self._get_k6_params()
        else:
            workload_name = "Sysbench"
            latency_percentile = "p95"
            sysbench_output_path = Path(self.config.output_dir).parent / "output" / "sysbench_output.txt"
            sysbench_results = parse_sysbench_output(sysbench_output_path)
            sysbench_params = self._get_sysbench_params()

        # Enrich intervals with per-interval Prometheus samples (CPU/mem/net/disk).
        if sysbench_results and sysbench_results.get("intervals"):
            interval_step = 10
            if self.config.workload_type == "sysbench":
                if sysbench_params and sysbench_params.get("report-interval"):
                    try:
                        interval_step = int(sysbench_params["report-interval"])
                    except ValueError:
                        pass
                elif len(sysbench_results["intervals"]) >= 2:
                    t0 = sysbench_results["intervals"][0]["time"]
                    t1 = sysbench_results["intervals"][1]["time"]
                    if t1 > t0:
                        interval_step = t1 - t0
            print(f"Enriching {len(sysbench_results['intervals'])} {workload_name} intervals with Prometheus metrics (step={interval_step}s)...")
            sysbench_results["intervals"] = self.enrich_intervals_with_metrics(
                sysbench_results["intervals"], interval_step
            )

        report_data = {
            "title": self.config.title,
            "workload_name": workload_name,
            "latency_percentile": latency_percentile,
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
            "yb_metrics_index": self.yb_metrics_index,
            "metrics_dump_url": "__METRICS_DUMP_URL__",
        }

        return template.render(**report_data)

    def _upload_to_s3(self, local_file: Path, s3_key: str):
        """Upload a file to S3 using aws cli."""
        m = re.match(r'https?://(.+?)\.s3[.-]website[.-].*', self.config.metrics_dump_base_url)
        if not m:
            m = re.match(r'https?://(.+?)\.s3\..*', self.config.metrics_dump_base_url)
        if not m:
            print(f"Warning: cannot parse S3 bucket from {self.config.metrics_dump_base_url}", file=sys.stderr)
            return
        bucket = m.group(1)
        cmd = ["aws", "s3", "cp", str(local_file), f"s3://{bucket}/{s3_key}"]
        aws_profile = os.environ.get("AWS_PROFILE", "")
        if aws_profile:
            cmd = ["env", f"AWS_PROFILE={aws_profile}"] + cmd
        print(f"Uploading to s3://{bucket}/{s3_key}...")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            print(f"Uploaded to S3: {self.config.metrics_dump_base_url}/{s3_key}")
        else:
            print(f"Warning: S3 upload failed: {result.stderr.strip()}", file=sys.stderr)

    def save_report(self, html_content: str):
        """Save report to file."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M")
        output_dir = Path(self.config.output_dir) / timestamp
        output_dir.mkdir(parents=True, exist_ok=True)

        # Resolve metrics dump URL now that timestamp is known.
        if self.config.metrics_dump_base_url:
            dump_url = f"{self.config.metrics_dump_base_url}/reports/{timestamp}/metrics_dump.json.gz"
        else:
            dump_url = "./metrics_dump.json.gz"
        html_content = html_content.replace("__METRICS_DUMP_URL__", dump_url)

        output_file = output_dir / "report.html"
        with open(output_file, "w") as f:
            f.write(html_content)

        print(f"Report saved to: {output_file}")

        # Save YB metrics dump for the Metrics Explorer tab (gzip compressed).
        if self.yb_dump:
            import gzip as _gzip
            dump_file = output_dir / "metrics_dump.json.gz"
            raw = json.dumps(self.yb_dump, separators=(",", ":")).encode()
            with _gzip.open(dump_file, "wb") as f:
                f.write(raw)
            size_mb = dump_file.stat().st_size / 1024 / 1024
            raw_mb = len(raw) / 1024 / 1024
            print(f"Saved YB metrics dump: {dump_file} ({size_mb:.1f} MB gzip, {raw_mb:.1f} MB raw, {len(self.yb_dump)} series)")

            # Upload to S3 if configured.
            if self.config.metrics_dump_base_url:
                s3_key = f"reports/{timestamp}/metrics_dump.json.gz"
                self._upload_to_s3(dump_file, s3_key)

        # Copy workload output files from unified output/ directory
        workload_dir = Path(self.config.output_dir).parent / "output"
        for spec_name in ["RUN_NODE_SPEC.txt", "CLIENT_NODE_SPEC.txt", "test_times.txt"]:
            src = workload_dir / spec_name
            if src.exists():
                shutil.copy(src, output_dir / spec_name)
                print(f"Copied {spec_name}")
        if self.config.workload_type == "k6":
            for k6_file in sorted(workload_dir.glob("k6_output_*.txt")):
                shutil.copy(k6_file, output_dir / k6_file.name)
                print(f"Copied {k6_file.name}")
            self._save_k6_configmap(output_dir)
        else:
            sysbench_output = workload_dir / "sysbench_output.txt"
            if sysbench_output.exists():
                shutil.copy(sysbench_output, output_dir / "sysbench_output.txt")
                print(f"Copied sysbench_output.txt")
            for pod_file in sorted(workload_dir.glob("sysbench_output_*.txt")):
                shutil.copy(pod_file, output_dir / pod_file.name)
                print(f"Copied {pod_file.name}")
            self._save_sysbench_configmap(output_dir)

        return output_file

    def collect_k6_results_from_prometheus(self, step: int = 10) -> Optional[dict]:
        """Build benchmark results dict from k6 Prometheus metrics.

        Returns the same structure as parse_sysbench_output() so the template
        can use the same variables.
        """
        start = self.config.start_time
        end = self.config.end_time

        # TPS from k6 iterations counter
        tps_series = self.prometheus.query_range(
            'sum(irate(k6_iterations_total[30s]))',
            start, end, step
        )

        # Insert latency p95 — requires K6_PROMETHEUS_RW_TREND_STATS=p(95),...
        lat_series = self.prometheus.query_range(
            'k6_iteration_duration_p95',
            start, end, step
        )

        if not tps_series:
            print("Warning: no k6_iterations_total data in Prometheus", file=sys.stderr)
            return None

        s = tps_series[0]
        intervals = []
        for ts, tps_val in zip(s.timestamps, s.values):
            t_offset = int(ts - start)
            lat_val = 0.0
            if lat_series and lat_series[0].values:
                lat_s = lat_series[0]
                closest_idx = min(range(len(lat_s.timestamps)),
                                  key=lambda i: abs(lat_s.timestamps[i] - ts))
                if abs(lat_s.timestamps[closest_idx] - ts) <= step:
                    # k6 iteration_duration is in seconds; convert to ms
                    lat_val = lat_s.values[closest_idx] * 1000.0

            intervals.append({
                "time": t_offset,
                "tps": tps_val,
                "lat_95": lat_val,
                "err_s": 0.0,
            })

        # Summary stats
        result = {"intervals": intervals}

        # Total iterations
        total_series = self.prometheus.query_range(
            'sum(k6_iterations_total)', end - 1, end, step
        )
        if total_series and total_series[0].values:
            result["transactions"] = int(total_series[0].values[-1])

        non_zero_tps = [iv["tps"] for iv in intervals if iv["tps"] > 0]
        if non_zero_tps:
            result["tps"] = sum(non_zero_tps) / len(non_zero_tps)

        non_zero_lat = [iv["lat_95"] for iv in intervals if iv["lat_95"] > 0]
        if non_zero_lat:
            result["lat_avg"] = sum(non_zero_lat) / len(non_zero_lat)
            result["lat_min"] = min(non_zero_lat)
            result["lat_max"] = max(non_zero_lat)
            result["lat_p95"] = sorted(non_zero_lat)[int(len(non_zero_lat) * 0.95)]

        result["elapsed"] = end - start
        return result

    def _get_k6_params(self) -> Optional[dict]:
        """Get k6 parameters from the k6 pod's env vars."""
        cmd = [
            "kubectl", "--context", self.config.kube_context,
            "-n", self.config.namespace,
            "get", "pod", "-l", "app.kubernetes.io/component=k6",
            "-o", "jsonpath={.items[0].spec.containers[0].env}"
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0 and result.stdout.strip():
                envs = json.loads(result.stdout)
                params = {}
                sensitive = {"PG_PASS", "PG_USER", "PG_HOST", "PG_PORT",
                             "K6_PROMETHEUS_RW_SERVER_URL"}
                for e in envs:
                    name = e.get("name", "")
                    if name not in sensitive:
                        params[name] = e.get("value", "")
                return params if params else None
        except Exception:
            pass
        return None

    def _save_k6_configmap(self, output_dir: Path):
        """Save the k6 scripts configmap for reference."""
        configmap_name = f"{self.config.release_name}-k6-scripts"
        cmd = [
            "kubectl", "--context", self.config.kube_context,
            "-n", self.config.namespace,
            "get", "configmap", configmap_name,
            "-o", "yaml"
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                configmap_file = output_dir / "k6-configmap.yaml"
                with open(configmap_file, "w") as f:
                    f.write(result.stdout)
                print(f"Saved k6 configmap to: {configmap_file}")
            else:
                print(f"Warning: Could not get k6 configmap: {result.stderr}", file=sys.stderr)
        except Exception as e:
            print(f"Warning: Failed to save k6 configmap: {e}", file=sys.stderr)

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
    parser.add_argument("--metrics-dump-base-url", default="",
                        help="S3 website base URL for metrics dump (e.g. http://bucket.s3-website.region.amazonaws.com)")
    parser.add_argument("--workload-type", default="sysbench", choices=["sysbench", "k6"],
                        help="Workload type (sysbench or k6)")

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
        metrics_dump_base_url=args.metrics_dump_base_url,
        workload_type=args.workload_type,
    )

    generator = ReportGenerator(config)
    generator.validate_connectivity()
    html = generator.generate_report()
    generator.save_report(html)


if __name__ == "__main__":
    main()
