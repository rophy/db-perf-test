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
- **YugabyteDB** - Distributed PostgreSQL-compatible database
- **Prometheus** - Metrics collection for performance reports

## Prerequisites

- Docker
- kubectl
- Minikube (for local testing) or AWS CLI (for cloud deployment)
- Helm 3.x
- Python 3 with Jinja2 (`pip install Jinja2`)

## Quick Start (Minikube)

```bash
# 1. Setup minikube with YugabyteDB
make setup-minikube

# 2. Wait for YugabyteDB pods to be ready
kubectl --context minikube get pods -n yugabyte-test -w

# 3. Deploy sysbench and Prometheus
make deploy ENV=minikube

# 4. Prepare sysbench tables
make sysbench-prepare

# 5. Warmup run (5 min, no metrics captured)
make sysbench-warm

# 6. Run benchmark (records timestamps for report)
make sysbench-run

# 7. Generate HTML performance report
make report
```

Reports are saved to `reports/<timestamp>/report.html`.

## Project Structure

```
.
├── config/
│   └── sysbench/              # Sysbench entrypoint script
├── docker/
│   └── sysbench-yb/           # YugabyteDB sysbench fork Dockerfile
├── k8s/
│   ├── base/
│   │   ├── databases/
│   │   │   └── yugabytedb/    # YugabyteDB Helm values
│   │   ├── sysbench/          # Sysbench deployment
│   │   └── prometheus/        # Monitoring
│   └── overlays/
│       ├── minikube/          # Minikube-specific patches
│       └── aws/               # AWS-specific patches
├── scripts/
│   └── report-generator/      # HTML report generation
└── Makefile
```

## Makefile Targets

### Sysbench Operations

| Target | Description |
|--------|-------------|
| `make sysbench-prepare` | Create tables and load test data |
| `make sysbench-warm` | Warmup run (5 min default, no metrics captured) |
| `make sysbench-run` | Run benchmark with timestamps for report |
| `make sysbench-cleanup` | Drop benchmark tables |
| `make sysbench-config` | Show current configuration |
| `make sysbench-shell` | Open shell in sysbench container |
| `make report` | Generate HTML performance report |

### Infrastructure

| Target | Description |
|--------|-------------|
| `make setup-minikube` | Setup minikube with YugabyteDB |
| `make deploy` | Deploy sysbench and Prometheus |
| `make status` | Show status of all components |
| `make ysql` | Connect to YugabyteDB YSQL shell |
| `make port-forward-prometheus` | Port forward Prometheus to localhost:9090 |
| `make clean` | Delete all resources |

## Configuration

### Sysbench Settings

Defaults follow [YugabyteDB official benchmark docs](https://docs.yugabyte.com/stable/benchmark/sysbench-ysql/).

| Variable | Default | Description |
|----------|---------|-------------|
| `SYSBENCH_TABLES` | 20 | Number of tables |
| `SYSBENCH_TABLE_SIZE` | 5000000 | Rows per table |
| `SYSBENCH_THREADS` | 60 | Concurrent threads |
| `SYSBENCH_TIME` | 1800 | Test duration (seconds) |
| `SYSBENCH_WARM_TIME` | 300 | Warmup duration (seconds) |
| `SYSBENCH_WARMUP` | 0 | In-run warmup (deprecated, use sysbench-warm instead) |
| `SYSBENCH_WORKLOAD` | oltp_read_write | Workload type |

Example with custom settings:
```bash
make sysbench-prepare SYSBENCH_TABLES=20 SYSBENCH_TABLE_SIZE=5000000
make sysbench-warm SYSBENCH_THREADS=60
make sysbench-run SYSBENCH_THREADS=60
make report
```

### YugabyteDB-specific Options

The sysbench image uses YugabyteDB's fork which includes optimizations:

| Option | Default | Description |
|--------|---------|-------------|
| `SYSBENCH_RANGE_KEY_PARTITIONING` | false | Use range partitioning |
| `SYSBENCH_SERIAL_CACHE_SIZE` | 1000 | Serial column cache size |
| `SYSBENCH_CREATE_SECONDARY` | true | Create secondary index |

### Available Workloads

- `oltp_read_write` - Mixed read/write transactions
- `oltp_read_only` - Read-only transactions
- `oltp_write_only` - Write-only transactions
- `oltp_update_index` - Index update operations
- `oltp_update_non_index` - Non-index update operations
- `oltp_insert` - Insert operations
- `oltp_delete` - Delete operations

## Performance Reports

After running `make sysbench-warm` and `make sysbench-run`, generate a report with `make report`.
The warmup phase ensures the system is warmed up before metrics are captured.

The report includes:
- CPU utilization per pod
- Memory usage over time
- Network I/O statistics
- Min/Avg/Max summary table
- Interactive Chart.js visualizations

## Monitoring

### Prometheus Metrics

Access Prometheus UI:
```bash
make port-forward-prometheus
# Open http://localhost:9090
```

YugabyteDB exposes metrics on port 9000 for both masters and tservers.

## HammerDB (Deprecated)

> **Note:** HammerDB support is outdated and needs revisiting. The TPROC-C workload did not generate sufficient CPU pressure on YugabyteDB in our tests. Use sysbench instead.

Legacy HammerDB targets still exist but are not maintained:
- `make hammerdb-build`
- `make hammerdb-run`
- `make hammerdb-delete`

## Troubleshooting

### Sysbench can't connect to YugabyteDB

Check that YugabyteDB is running:
```bash
kubectl --context minikube get svc -n yugabyte-test
kubectl --context minikube get pods -n yugabyte-test
```

### Pod scheduling issues

Minikube has limited resources. Check node capacity:
```bash
kubectl --context minikube describe node minikube | grep -A 10 "Allocated resources"
```

### View logs

```bash
make sysbench-logs
kubectl --context minikube logs -n yugabyte-test yb-tserver-0
```
