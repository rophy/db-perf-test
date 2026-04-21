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

## Environments

Three deployment environments are supported:

| Environment | Infra | Use Case |
|---|---|---|
| **minikube** | minikube (KVM2) | Local development, quick benchmarks |
| **AWS** | k3s on c7i.8xlarge (via kube-sandbox terraform) | Production-scale benchmarks |
| **k3s-virsh** | libvirt VMs + k3s | Performance tuning lab with I/O simulation |

### k3s-virsh: Performance Tuning Lab

Uses libvirt/virsh-managed VMs with k3s for full control over infrastructure resources:

- **dm-delay** — inject per-I/O latency on tserver storage (inside VMs)
- **virsh blkdeviotune** — throttle disk throughput/IOPS (from host, requires `cache=none`)
- **virsh setvcpus / setmem** — adjust CPU/memory per VM

Topology: 1 control node (4 CPU / 8 GB) + 3 worker nodes (4 CPU / 8 GB), Ubuntu 24.04.

## Prerequisites

- kubectl
- Helm 3.x
- Kubernetes cluster (minikube, k3s-virsh, or AWS via kube-sandbox)
- Python 3 with Jinja2 (`pip install Jinja2`) for report generation
- Node.js + npm for report JS vendor libs (`make vendor`)
- For k3s-virsh: libvirt, virt-install, qemu-img, genisoimage

## Quick Start

### Minikube

```bash
./scripts/setup-minikube.sh
make deploy-minikube
make sysbench-cleanup && make sysbench-prepare && make sysbench-trigger
make sysbench-run
make report
```

### AWS

```bash
make deploy-aws KUBE_CONTEXT=kube-sandbox
make sysbench-cleanup KUBE_CONTEXT=kube-sandbox
make sysbench-prepare KUBE_CONTEXT=kube-sandbox
make sysbench-trigger KUBE_CONTEXT=kube-sandbox
make sysbench-run KUBE_CONTEXT=kube-sandbox
```

### k3s-virsh (Performance Tuning Lab)

```bash
# Create VMs and install k3s
./scripts/setup-k3s-virsh.sh

# Setup storage (with optional disk latency)
DISK_DELAY_MS=50 ./scripts/setup-slow-disk.sh

# Deploy YugabyteDB
make deploy-k3s-virsh KUBE_CONTEXT=k3s-virsh

# Run benchmark
make sysbench-cleanup KUBE_CONTEXT=k3s-virsh
make sysbench-prepare KUBE_CONTEXT=k3s-virsh
make sysbench-trigger KUBE_CONTEXT=k3s-virsh
make sysbench-run KUBE_CONTEXT=k3s-virsh

# Optional: throttle disk throughput on running cluster (non-destructive)
DISK_BW_MBPS=10 ./scripts/setup-slow-throughput.sh

# Optional: change dm-delay latency without reformatting the disk
DISK_DELAY_MS=5 ./scripts/adjust-disk-delay.sh

# Cleanup
make clean KUBE_CONTEXT=k3s-virsh
./scripts/teardown-k3s-virsh.sh
```

Reports are saved to `reports/<timestamp>/report.html`.

## Project Structure

```
.
├── charts/
│   └── yb-benchmark/              # Helm chart
│       ├── Chart.yaml
│       ├── charts/yugabyte/       # Vendored YugabyteDB subchart (v2.23.1)
│       ├── values-aws.yaml        # AWS production settings
│       ├── values-minikube.yaml   # Minikube dev settings
│       ├── values-k3s-virsh.yaml  # k3s-virsh tuning lab settings
│       └── templates/
│           ├── sysbench.yaml           # Sysbench StatefulSet
│           ├── sysbench-configmap.yaml # Sysbench scripts (prepare/run/cleanup)
│           └── prometheus.yaml         # Prometheus + node-exporter + cAdvisor
├── scripts/
│   ├── setup-minikube.sh          # Minikube cluster setup
│   ├── setup-k3s-virsh.sh        # VM creation + k3s install
│   ├── teardown-k3s-virsh.sh     # VM cleanup
│   ├── setup-slow-disk.sh        # dm-delay storage setup
│   ├── setup-slow-throughput.sh   # virsh blkdeviotune wrapper
│   ├── trigger-setup.sql          # cleanup_duplicate_k trigger DDL
│   └── report-generator/          # HTML report generation
├── reports/                       # Generated reports (committed to git)
│   ├── vendor/                    # JS libs for reports (built by make vendor, gitignored)
│   └── <timestamp>/report.html
├── package.json                   # JS vendor deps (chart.js, plugins)
├── .env.example                   # Environment variables template
├── Makefile                       # Deployment and benchmark targets
└── README.md
```

## Makefile Targets

### Deployment

| Target | Description |
|--------|-------------|
| `make deploy-minikube` | Deploy with minikube-optimized settings |
| `make deploy-aws` | Deploy with AWS-optimized settings |
| `make deploy-k3s-virsh` | Deploy on k3s-virsh tuning lab |
| `make deploy-benchmarks` | Deploy benchmarks only (use existing YugabyteDB) |
| `make clean` | Delete all resources |

### Sysbench Operations

| Target | Description |
|--------|-------------|
| `make sysbench-prepare` | Create tables and load test data (params from values file) |
| `make sysbench-trigger` | Install `cleanup_duplicate_k` trigger on all sbtest tables |
| `make sysbench-run` | Run benchmark (params from values file) |
| `make sysbench-cleanup` | Drop benchmark tables |
| `make sysbench-shell` | Open shell in sysbench container |
| `make vendor` | Install JS vendor libs for reports (npm) |
| `make report` | Generate HTML performance report |

### Utilities

| Target | Description |
|--------|-------------|
| `make status` | Show status of all components |
| `make ysql` | Connect to YugabyteDB YSQL shell |
| `make port-forward-prometheus` | Port forward Prometheus to localhost:9090 |

### k3s-virsh Infrastructure

| Target | Description |
|--------|-------------|
| `make setup-k3s-virsh` | Create VMs and install k3s cluster |
| `make teardown-k3s-virsh` | Destroy VMs and cleanup |
| `make setup-slow-disk` | Create tserver storage with dm-delay (`DISK_DELAY_MS=50`). **Destructive** — reformats disk, wipes YB data. Use for initial setup or full reset. |
| `make adjust-disk-delay` | Change dm-delay live (`DISK_DELAY_MS=5`). **Non-destructive** — data preserved via `dmsetup suspend/reload/resume`. Use to iterate on latency. |
| `make setup-slow-throughput` | Throttle VM disk throughput (`DISK_BW_MBPS=10 DISK_IOPS=200`). **Non-destructive** — `virsh blkdeviotune --live`. Safe to re-run with new values. |

## Configuration

All sysbench parameters are defined in Helm values files (single source of truth).

### Sysbench Settings

Parameters follow [YugabyteDB official benchmark docs](https://docs.yugabyte.com/stable/benchmark/sysbench-ysql/).

| Parameter | AWS | k3s-virsh | Minikube | Description |
|-----------|-----|-----------|----------|-------------|
| `sysbench.tables` | 24 | 10 | 10 | Number of tables |
| `sysbench.tableSize` | 100000 | 100000 | 100000 | Rows per table |
| `sysbench.threads` | 21000 | 128 | 24 | Concurrent threads |
| `sysbench.time` | 300 | 120 | 120 | Test duration (seconds) |
| `sysbench.warmupTime` | 90 | 30 | 30 | In-run warmup (seconds) |
| `sysbench.workload` | oltp_insert | oltp_insert | oltp_read_write | Workload type |

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

- `oltp_insert` - Single-row insert transactions (used for write scaling benchmarks)
- `oltp_read_write` - Mixed read/write transactions
- `oltp_read_only` - Read-only transactions
- `oltp_write_only` - Write-only transactions

## Performance Reports

After `make sysbench-run`, generate a report with `make report`.

The report includes:
- Per-interval TPS, latency, CPU/node, memory, network, disk IOPS
- CPU utilization per pod (container-level via cAdvisor)
- Memory usage over time
- Network I/O statistics
- Metrics Explorer tab with all YugabyteDB metrics (loaded from S3)
- Interactive Chart.js visualizations (vendor libs installed via `make vendor`)

Reports are published to GitHub Pages at `https://rophy.github.io/db-perf-test/`.

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
