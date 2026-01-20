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
# 1. Deploy full stack (YugabyteDB + sysbench + Prometheus)
make deploy KUBE_CONTEXT=minikube

# 2. Wait for YugabyteDB pods to be ready
make status

# 3. Prepare sysbench tables (20 tables x 5M rows)
make sysbench-prepare

# 4. Run benchmark (30 min with 5 min warmup)
make sysbench-run

# 5. Generate HTML performance report
make report
```

Reports are saved to `reports/<timestamp>/report.html`.

## Project Structure

```
.
├── charts/
│   └── yb-benchmark/           # Helm chart
│       ├── Chart.yaml          # YugabyteDB as optional dependency
│       ├── values.yaml         # Default values
│       └── templates/
│           ├── sysbench.yaml   # Sysbench deployment
│           └── prometheus.yaml # Prometheus stack
├── scripts/
│   └── report-generator/       # HTML report generation
├── Makefile                    # Single source of truth for sysbench parameters
└── README.md
```

## Makefile Targets

### Deployment

| Target | Description |
|--------|-------------|
| `make deploy` | Deploy full stack (YugabyteDB + sysbench + Prometheus) |
| `make deploy-benchmarks` | Deploy benchmarks only (use existing YugabyteDB) |
| `make clean` | Delete all resources |

### Sysbench Operations

| Target | Description |
|--------|-------------|
| `make sysbench-prepare` | Create tables and load test data |
| `make sysbench-run` | Run benchmark (30 min with 5 min in-run warmup) |
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

All sysbench parameters are defined in the Makefile (single source of truth).

### Sysbench Settings

Parameters follow [YugabyteDB official benchmark docs](https://docs.yugabyte.com/stable/benchmark/sysbench-ysql/).

| Variable | Default | Description |
|----------|---------|-------------|
| `SYSBENCH_TABLES` | 20 | Number of tables |
| `SYSBENCH_TABLE_SIZE` | 5000000 | Rows per table |
| `SYSBENCH_THREADS` | 60 | Concurrent threads |
| `SYSBENCH_TIME` | 1800 | Test duration (seconds) |
| `SYSBENCH_WARMUP` | 300 | In-run warmup (seconds) |
| `SYSBENCH_WORKLOAD` | oltp_read_write | Workload type |

Example with custom settings:
```bash
make sysbench-prepare SYSBENCH_TABLES=10
make sysbench-run SYSBENCH_THREADS=120 SYSBENCH_TIME=3600
make report
```

### YugabyteDB-specific Flags

These flags are hardcoded in the Makefile per YugabyteDB docs:

| Flag | Value | Description |
|------|-------|-------------|
| `--range_selects` | false | **CRITICAL**: Prevents 100x slowdown from cross-tablet scans |
| `--range_key_partitioning` | false | Use hash partitioning |
| `--serial_cache_size` | 1000 | Serial column cache size |
| `--create_secondary` | true | Create secondary index |

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
# Full stack
helm install yb-bench ./charts/yb-benchmark -n yugabyte-test --create-namespace

# Benchmarks only (existing YugabyteDB)
helm install yb-bench ./charts/yb-benchmark -n yugabyte-test \
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
