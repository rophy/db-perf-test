# YugabyteDB Benchmark Infrastructure

Benchmark infrastructure for evaluating YugabyteDB performance using sysbench OLTP workloads.

## Architecture

```
┌─────────────────┐                ┌──────────────────┐
│    Sysbench     │───────────────▶│   YugabyteDB     │
│   (OLTP)        │   PostgreSQL   │   (YSQL:5433)    │
└─────────────────┘                └──────────────────┘
                                          │
                                   ┌──────▼──────┐
                                   │  Prometheus │
                                   └─────────────┘
```

**Components:**
- **Sysbench** - Database benchmark tool using YugabyteDB's fork with YB-specific optimizations
- **YugabyteDB** - Distributed PostgreSQL-compatible database (deployed as Helm subchart)
- **Prometheus** - Metrics collection for performance reports

## Prerequisites

- kubectl
- Helm 3.x
- Kubernetes cluster (minikube for local, or remote cluster)
- Python 3 with Jinja2 (`pip install Jinja2`) for report generation

## Quick Start

```bash
# For minikube (local development)
make deploy-minikube KUBE_CONTEXT=minikube

# For AWS (production benchmarks)
make deploy-aws KUBE_CONTEXT=my-eks-cluster

# Wait for YugabyteDB pods to be ready
make status

# Prepare sysbench tables (parameters from values file)
make sysbench-prepare

# Run benchmark (parameters from values file)
make sysbench-run

# Generate HTML performance report
make report
```

Reports are saved to `reports/<timestamp>/report.html`.

## Project Structure

```
.
├── charts/
│   └── yb-benchmark/              # Helm chart
│       ├── Chart.yaml             # YugabyteDB as optional dependency
│       ├── values-aws.yaml        # AWS production settings
│       ├── values-minikube.yaml   # Minikube dev settings
│       └── templates/
│           ├── sysbench.yaml           # Sysbench deployment
│           ├── sysbench-configmap.yaml # Sysbench scripts (prepare/run/cleanup)
│           └── prometheus.yaml         # Prometheus stack
├── scripts/
│   └── report-generator/          # HTML report generation
├── Makefile                       # Deployment and benchmark targets
└── README.md
```

## Makefile Targets

### Deployment

| Target | Description |
|--------|-------------|
| `make deploy-minikube` | Deploy with minikube-optimized settings (1 master, 1 tserver) |
| `make deploy-aws` | Deploy with AWS-optimized settings (3 masters, 3 tservers) |
| `make deploy-benchmarks` | Deploy benchmarks only (use existing YugabyteDB) |
| `make clean` | Delete all resources |

### Sysbench Operations

| Target | Description |
|--------|-------------|
| `make sysbench-prepare` | Create tables and load test data (params from values file) |
| `make sysbench-run` | Run benchmark (params from values file) |
| `make sysbench-cleanup` | Drop benchmark tables |
| `make sysbench-shell` | Open shell in sysbench container |
| `make report` | Generate HTML performance report |

### Utilities

| Target | Description |
|--------|-------------|
| `make status` | Show status of all components |
| `make ysql` | Connect to YugabyteDB YSQL shell |
| `make port-forward-prometheus` | Port forward Prometheus to localhost:9090 |

## Configuration

All sysbench parameters are defined in Helm values files (single source of truth).

### Sysbench Settings

Parameters follow [YugabyteDB official benchmark docs](https://docs.yugabyte.com/stable/benchmark/sysbench-ysql/).

| Parameter | AWS Default | Minikube Default | Description |
|-----------|-------------|------------------|-------------|
| `sysbench.tables` | 20 | 2 | Number of tables |
| `sysbench.tableSize` | 5000000 | 1000 | Rows per table |
| `sysbench.threads` | 60 | 2 | Concurrent threads |
| `sysbench.time` | 1800 | 60 | Test duration (seconds) |
| `sysbench.warmupTime` | 300 | 10 | In-run warmup (seconds) |
| `sysbench.workload` | oltp_read_write | oltp_read_write | Workload type |

To customize, edit `charts/yb-benchmark/values-*.yaml` and redeploy.

### YugabyteDB-specific Flags

These flags are configured in `sysbench.*` per YugabyteDB docs:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `sysbench.rangeSelects` | false | **CRITICAL**: Prevents 100x slowdown from cross-tablet scans |
| `sysbench.rangeKeyPartitioning` | false | Use hash partitioning |
| `sysbench.serialCacheSize` | 1000 | Serial column cache size |
| `sysbench.createSecondary` | true | Create secondary index |

### Available Workloads

- `oltp_read_write` - Mixed read/write transactions (default)
- `oltp_read_only` - Read-only transactions
- `oltp_write_only` - Write-only transactions

## Performance Reports

After `make sysbench-run`, generate a report with `make report`.

The report includes:
- CPU utilization per pod
- Memory usage over time
- Network I/O statistics
- Min/Avg/Max summary table
- Interactive Chart.js visualizations

## Helm Chart

The chart can be used standalone:

```bash
# AWS production
helm install yb-bench ./charts/yb-benchmark -n yugabyte-test --create-namespace \
  -f ./charts/yb-benchmark/values-aws.yaml

# Minikube development
helm install yb-bench ./charts/yb-benchmark -n yugabyte-test --create-namespace \
  -f ./charts/yb-benchmark/values-minikube.yaml

# Benchmarks only (existing YugabyteDB)
helm install yb-bench ./charts/yb-benchmark -n yugabyte-test \
  -f ./charts/yb-benchmark/values-minikube.yaml \
  --set yugabyte.enabled=false
```

## Troubleshooting

### Sysbench can't connect to YugabyteDB

Check that YugabyteDB is running:
```bash
make status
kubectl --context minikube get pods -n yugabyte-test
```

### View logs

```bash
make sysbench-logs
kubectl --context minikube logs -n yugabyte-test yb-tserver-0
```
