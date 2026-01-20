# Sysbench Testing for YugabyteDB

This document describes sysbench configuration and benchmark results for YugabyteDB YSQL.

## YugabyteDB Fork of Sysbench

We use the [YugabyteDB fork of sysbench](https://github.com/yugabyte/sysbench) which includes optimizations specific to YugabyteDB:

- `--range_key_partitioning` - Controls whether to use range-based partitioning
- `--serial_cache_size` - Sequence cache size for faster ID generation (default: 1000)
- `--create_secondary` - Whether to create secondary indexes
- `--warmup-time` - Warmup period before measuring
- `--thread-init-timeout` - Connection initialization timeout

Image: `rophy/sysbench:yugabyte-20260119`

## Recommended Configuration

Based on [YugabyteDB official documentation](https://docs.yugabyte.com/stable/benchmark/sysbench-ysql/):

| Parameter | Value | Description |
|-----------|-------|-------------|
| `--threads` | 60 | Concurrent connections |
| `--time` | 300 | Test duration in seconds |
| `--warmup-time` | 60 | Warmup period before measuring |
| `--range_selects` | false | Disable expensive range scans |
| `--point_selects` | 10 | Point lookups per transaction |
| `--index_updates` | 10 | Index update operations |
| `--non_index_updates` | 10 | Non-index update operations |
| `--serial_cache_size` | 1000 | Sequence cache for faster inserts |
| `--thread-init-timeout` | 90 | Connection timeout in seconds |

## Benchmark Results

### Test Environment
- **Cluster**: kube-sandbox (AWS K3s, 3 nodes)
- **YugabyteDB**: 3 tservers, RF=3
- **Data**: 10 tables x 100,000 rows = 1M rows total

### oltp_read_write Results

#### Standard Sysbench (severalnines/sysbench:latest)

Using default sysbench without YugabyteDB optimizations:

| Metric | Value |
|--------|-------|
| TPS | 8.63 |
| QPS | ~310 |
| 95th Latency | 10,158ms |
| Error Rate | 23/sec |

#### YugabyteDB-Optimized Sysbench

Using YugabyteDB fork with recommended settings:

| Metric | Value |
|--------|-------|
| TPS | **199.82** |
| QPS | **6,904** |
| 95th Latency | **376ms** |
| Error Rate | 5.2/sec |

### Improvement Summary

| Metric | Improvement |
|--------|-------------|
| Throughput (TPS) | **23x better** |
| Queries/sec | **22x better** |
| Latency (95th) | **27x faster** |
| Error Rate | **77% reduction** |

## Scaling Tests

### Service Type: Headless vs ClusterIP

The default YugabyteDB Helm chart creates a headless service (`yb-tservers`) which doesn't load-balance connections. Configuring a ClusterIP service (`yb-tserver-service`) enables proper load distribution.

**Test Configuration:**
- 3 tservers, 180 threads, 300s duration
- 10 tables x 100,000 rows

| Service Type | TPS | QPS | 95th Latency | Avg CPU/tserver |
|--------------|-----|-----|--------------|-----------------|
| Headless (`yb-tservers`) | 213.32 | 7,587 | 1,304ms | ~200% (unbalanced) |
| ClusterIP (`yb-tserver-service`) | **321.63** | **11,481** | **877ms** | **560%** (balanced) |

**Improvement:** 51% higher TPS, 33% lower latency

**Load Distribution with ClusterIP (3 tservers):**

| TServer | Avg CPU | Share of Load |
|---------|---------|---------------|
| yb-tserver-0 | 534% | 31.8% |
| yb-tserver-1 | 586% | 34.8% |
| yb-tserver-2 | 562% | 33.4% |

### Horizontal Scaling: 3 vs 4 TServers

**Test Configuration:**
- ClusterIP service, 180 threads, 300s duration
- 10 tables x 100,000 rows

| TServers | TPS | QPS | 95th Latency | Avg CPU/tserver |
|----------|-----|-----|--------------|-----------------|
| 3 | 321.63 | 11,481 | 877ms | 560% |
| 4 | **409.87** | **14,625** | **682ms** | 554% |

**Improvement:** 27% higher TPS, 22% lower latency

**Load Distribution with 4 tservers:**

| TServer | Avg CPU | Share of Load |
|---------|---------|---------------|
| yb-tserver-0 | 550% | 24.8% |
| yb-tserver-1 | 578% | 26.1% |
| yb-tserver-2 | 546% | 24.6% |
| yb-tserver-3 | 541% | 24.4% |

### Thread Count Optimization (4 TServers)

Testing different thread counts to find the saturation point:

| Threads | TPS | QPS | 95th Latency | Avg CPU | Errors/s |
|---------|-----|-----|--------------|---------|----------|
| 180 | **409.87** | **14,625** | **682ms** | 554% | 32.29 |
| 240 | 396.65 | 14,381 | 1,051ms | 590% | 41.59 |

At 240 threads, performance degrades:
- TPS decreased 3.2%
- Latency increased 54%
- Error rate increased 29%

**Optimal: ~45 threads per tserver** (180 threads / 4 tservers)

### Scaling Summary

| Configuration | TPS | Scaling Factor |
|---------------|-----|----------------|
| 3 tservers (headless) | 213 | 1.0x (baseline) |
| 3 tservers (ClusterIP) | 322 | 1.51x |
| 4 tservers (ClusterIP), 180 threads | 410 | 1.92x |
| 4 tservers (ClusterIP), 240 threads | 397 | 1.86x (saturated) |

**Key Findings:**
1. **ClusterIP is essential** - Headless services don't load-balance, causing uneven CPU distribution
2. **Near-linear scaling** - Adding 33% more tservers (3→4) yielded 27% more throughput
3. **CPU saturation** - Each tserver peaks at ~800% CPU (8 cores), indicating compute-bound workload
4. **Optimal thread count** - ~45 threads per tserver maximizes throughput without saturation

## Key Optimizations Explained

### 1. Disable Range Selects (`--range_selects=false`)

Range queries require scanning multiple tablets across the distributed cluster. Disabling them focuses the benchmark on point lookups which YugabyteDB handles efficiently.

### 2. Serial Cache Size (`--serial_cache_size=1000`)

YugabyteDB sequences require distributed coordination. Caching 1000 values locally reduces round-trips during inserts.

### 3. Balanced Operations (`--point_selects=10`, `--index_updates=10`, etc.)

The default sysbench configuration uses range queries. Setting explicit counts for point operations creates a workload better suited for distributed databases.

### 4. Connection Timeout (`--thread-init-timeout=90`)

Distributed databases may take longer to establish connections. A 90-second timeout prevents premature failures during initialization.

### 5. Warmup Period (`--warmup-time=60`)

YugabyteDB benefits from warmup to populate caches and stabilize tablet leadership. A 60-second warmup ensures measurements reflect steady-state performance.

## Running the Benchmark

### Prepare Data

```bash
kubectl --context kube-sandbox exec -n yugabyte-test deployment/sysbench -- \
  /scripts/entrypoint.sh prepare
```

### Run Benchmark

```bash
kubectl --context kube-sandbox exec -n yugabyte-test deployment/sysbench -- \
  /scripts/entrypoint.sh run
```

### Cleanup

```bash
kubectl --context kube-sandbox exec -n yugabyte-test deployment/sysbench -- \
  /scripts/entrypoint.sh cleanup
```

## Configuration via Environment Variables

All settings can be overridden via environment variables in the Kubernetes deployment:

```yaml
env:
  - name: SYSBENCH_TABLES
    value: "10"
  - name: SYSBENCH_TABLE_SIZE
    value: "100000"
  - name: SYSBENCH_THREADS
    value: "60"
  - name: SYSBENCH_TIME
    value: "300"
  - name: SYSBENCH_WARMUP
    value: "60"
  - name: SYSBENCH_RANGE_SELECTS
    value: "false"
  - name: SYSBENCH_POINT_SELECTS
    value: "10"
  - name: SYSBENCH_INDEX_UPDATES
    value: "10"
  - name: SYSBENCH_NON_INDEX_UPDATES
    value: "10"
```

## References

- [YugabyteDB Sysbench Documentation](https://docs.yugabyte.com/stable/benchmark/sysbench-ysql/)
- [YugabyteDB Sysbench Fork](https://github.com/yugabyte/sysbench)
