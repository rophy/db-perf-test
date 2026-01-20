#!/usr/bin/env python3
"""
Stress Test Report Generator for YugabyteDB Sysbench Benchmarks

Generates HTML reports with Chart.js visualizations from Prometheus metrics.
"""

import argparse
import json
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
        self.cluster_spec = {}

    def collect_container_metrics(self):
        """Collect CPU, memory, network, disk metrics for pods."""
        pods_regex = "|".join(self.config.pods)

        # CPU usage (percentage)
        cpu_query = f'sum(rate(container_cpu_usage_seconds_total{{namespace="{self.config.namespace}",pod=~"{pods_regex}"}}[30s])) by (pod) * 100'
        self.metrics_data["cpu"] = self._query_and_aggregate(cpu_query, "CPU Usage (%)")

        # Memory usage (MB)
        mem_query = f'sum(container_memory_working_set_bytes{{namespace="{self.config.namespace}",pod=~"{pods_regex}"}}) by (pod) / 1024 / 1024'
        self.metrics_data["memory"] = self._query_and_aggregate(mem_query, "Memory Usage (MB)")

        # Network RX (bytes/s)
        net_rx_query = f'sum(rate(container_network_receive_bytes_total{{namespace="{self.config.namespace}",pod=~"{pods_regex}"}}[30s])) by (pod)'
        self.metrics_data["network_rx"] = self._query_and_aggregate(net_rx_query, "Network RX (B/s)")

        # Network TX (bytes/s)
        net_tx_query = f'sum(rate(container_network_transmit_bytes_total{{namespace="{self.config.namespace}",pod=~"{pods_regex}"}}[30s])) by (pod)'
        self.metrics_data["network_tx"] = self._query_and_aggregate(net_tx_query, "Network TX (B/s)")

        # Disk Read IOPS (ops/s)
        disk_read_iops_query = f'sum(rate(container_fs_reads_total{{namespace="{self.config.namespace}",pod=~"{pods_regex}"}}[30s])) by (pod)'
        self.metrics_data["disk_read_iops"] = self._query_and_aggregate(disk_read_iops_query, "Disk Read IOPS")

        # Disk Write IOPS (ops/s)
        disk_write_iops_query = f'sum(rate(container_fs_writes_total{{namespace="{self.config.namespace}",pod=~"{pods_regex}"}}[30s])) by (pod)'
        self.metrics_data["disk_write_iops"] = self._query_and_aggregate(disk_write_iops_query, "Disk Write IOPS")

        # Disk Read Throughput (MB/s)
        disk_read_throughput_query = f'sum(rate(container_fs_reads_bytes_total{{namespace="{self.config.namespace}",pod=~"{pods_regex}"}}[30s])) by (pod) / 1024 / 1024'
        self.metrics_data["disk_read_throughput"] = self._query_and_aggregate(disk_read_throughput_query, "Disk Read (MB/s)")

        # Disk Write Throughput (MB/s)
        disk_write_throughput_query = f'sum(rate(container_fs_writes_bytes_total{{namespace="{self.config.namespace}",pod=~"{pods_regex}"}}[30s])) by (pod) / 1024 / 1024'
        self.metrics_data["disk_write_throughput"] = self._query_and_aggregate(disk_write_throughput_query, "Disk Write (MB/s)")

    def collect_custom_metrics(self):
        """Collect custom rate and total metrics."""
        for metric_expr in self.config.rate_metrics:
            key = f"rate_{metric_expr.replace('{', '_').replace('}', '_').replace(',', '_')}"
            query = f"sum(rate({metric_expr}[30s]))"
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
                    "timestamps": s.timestamps,
                    "values": s.values
                }
                for s in series_list
            ]
        }

    def generate_report(self) -> str:
        """Generate HTML report."""
        # Collect cluster specifications
        self.cluster_spec = self.cluster_collector.collect()

        # Collect metrics
        print("Collecting container metrics...")
        self.collect_container_metrics()

        print("Collecting custom metrics...")
        self.collect_custom_metrics()

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

        report_data = {
            "title": self.config.title,
            "start_time": start_dt.strftime("%Y-%m-%d %H:%M:%S"),
            "end_time": end_dt.strftime("%Y-%m-%d %H:%M:%S"),
            "duration": f"{duration_min:.1f} minutes",
            "pods": self.config.pods,
            "metrics": self.metrics_data,
            "cluster_spec": self.cluster_spec,
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
        return output_file


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
    html = generator.generate_report()
    generator.save_report(html)


if __name__ == "__main__":
    main()
