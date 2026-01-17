# YugabyteDB Benchmark Infrastructure

Benchmark infrastructure for evaluating YugabyteDB performance using HammerDB TPROC-C (TPC-C like) workload.

## Architecture

```
┌─────────────────┐                ┌──────────────────┐
│   HammerDB      │───────────────▶│   YugabyteDB     │
│   (TPROC-C)     │   PostgreSQL   │   (YSQL:5433)    │
└─────────────────┘                └──────────────────┘
                                           │
                                    ┌──────▼──────┐
                                    │  Prometheus │
                                    └─────────────┘
```

**Components:**
- **HammerDB** - Industry-standard database benchmark tool running TPROC-C workload
- **YugabyteDB** - Distributed PostgreSQL-compatible database
- **Prometheus** - Metrics collection for YugabyteDB

## Prerequisites

- Docker
- kubectl
- Minikube (for local testing) or AWS CLI (for cloud deployment)
- Helm 3.x

## Quick Start (Minikube)

```bash
# 1. Setup minikube with YugabyteDB
make setup-minikube

# 2. Wait for YugabyteDB pods to be ready
kubectl --context minikube get pods -n yugabyte-test -w

# 3. Deploy HammerDB and Prometheus
make deploy ENV=minikube

# 4. Build TPROC-C schema
make build-schema

# 5. Run benchmark
make run-bench

# 6. Check results in YugabyteDB
make ysql
# Then: SELECT count(*) FROM tpcc.orders;
```

## Project Structure

```
.
├── config/
│   └── hammerdb/               # HammerDB TCL scripts
│       ├── entrypoint.sh       # Command router
│       ├── buildschema.tcl     # Schema build script
│       ├── runworkload.tcl     # Workload script
│       └── deleteschema.tcl    # Schema cleanup script
├── k8s/
│   ├── base/
│   │   ├── databases/
│   │   │   └── yugabytedb/     # YugabyteDB Helm values
│   │   ├── hammerdb/           # HammerDB deployment
│   │   └── prometheus/         # Monitoring
│   └── overlays/
│       ├── minikube/           # Minikube-specific patches
│       └── aws/                # AWS-specific patches
├── scripts/                    # Setup and deployment scripts
└── Makefile                    # Build and deployment commands
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make setup-minikube` | Setup minikube with YugabyteDB |
| `make deploy` | Deploy HammerDB and Prometheus |
| `make build-schema` | Build TPROC-C schema in YugabyteDB |
| `make run-bench` | Run TPROC-C benchmark |
| `make delete-schema` | Delete TPROC-C schema |
| `make status` | Show status of all components |
| `make logs` | Show HammerDB logs |
| `make ysql` | Connect to YugabyteDB YSQL shell |
| `make hammerdb-shell` | Open HammerDB CLI shell |
| `make port-forward-prometheus` | Port forward Prometheus to localhost:9090 |
| `make clean` | Delete all resources |

## Configuration

### HammerDB Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `HAMMERDB_WAREHOUSES` | 4 | Number of TPROC-C warehouses |
| `HAMMERDB_VUS` | 4 | Number of virtual users |
| `HAMMERDB_DURATION` | 5 | Test duration (minutes) |
| `HAMMERDB_RAMPUP` | 1 | Rampup time (minutes) |

Example with custom settings:
```bash
make build-schema HAMMERDB_WAREHOUSES=10 HAMMERDB_VUS=8
make run-bench HAMMERDB_VUS=8 HAMMERDB_DURATION=10
```

### Environment Variables (in HammerDB pod)

| Variable | Default | Description |
|----------|---------|-------------|
| `PG_HOST` | yb-tserver-service | Database host |
| `PG_PORT` | 5433 | YSQL port |
| `PG_SUPERUSER` | yugabyte | Admin user |
| `PG_SUPERPASS` | yugabyte | Admin password |
| `PG_USER` | tpcc | TPCC user |
| `PG_PASS` | tpcc | TPCC password |
| `PG_DBASE` | tpcc | TPCC database |

## TPROC-C Benchmark

TPROC-C is HammerDB's implementation of a TPC-C like workload. It simulates a wholesale supplier with:
- Warehouses, districts, and customers
- Order entry and fulfillment operations
- Stock level checks

Key metrics:
- **NOPM** (New Orders Per Minute) - Primary throughput metric
- **TPM** (Transactions Per Minute) - Total transaction throughput

## Monitoring

### Prometheus Metrics

Access Prometheus UI:
```bash
make port-forward-prometheus
# Open http://localhost:9090
```

YugabyteDB exposes metrics on port 9000 for both masters and tservers.

### Checking Data in YugabyteDB

```bash
make ysql
# Example queries:
\c tpcc
SELECT count(*) FROM warehouse;
SELECT count(*) FROM orders;
SELECT count(*) FROM new_order;
```

## Technology Stack

| Component | Version |
|-----------|---------|
| Kubernetes | 1.33+ |
| YugabyteDB | Latest |
| HammerDB | 4.12 |
| Prometheus | 2.48.0 |

## Future Extensibility

The infrastructure is designed to support additional databases:
```
k8s/base/databases/
├── yugabytedb/    # Current
├── citus/         # Future
├── mariadb/       # Future
└── tidb/          # Future
```

Usage pattern: `make deploy ENV=minikube DB=yugabytedb`

## Troubleshooting

### HammerDB can't connect to YugabyteDB

Check that YugabyteDB is running and the service is available:
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
make logs              # HammerDB logs
kubectl --context minikube logs -n yugabyte-test yb-tserver-0  # YugabyteDB logs
```
