# Analysis: oltp_insert Baseline (No Triggers)

**Report:** 20260328_0753
**Config:** dm-delay=5ms, IOPS cap=80, 3 tservers (4 vCPU / 2 P-cores pinned), 48 threads
**Tuning:** `bytes_durable_wal_write_mb=4`, `interval_durable_wal_write_ms=5000`
**Workload:** oltp_insert, no triggers

## Summary

| Metric | Value |
|--------|-------|
| TPS | 1,835.71 |
| QPS | 1,835.71 |
| p95 Latency | 37.56 ms |
| Errors | 0 (0.00/s) |
| Error % | 0% |

## Infrastructure Saturation

| Resource | Measured | Capacity | Utilization | Saturated? |
|----------|----------|----------|-------------|------------|
| Disk Write IOPS | 31-33 per tserver | 80 cap | 40% | No |
| Container CPU | 178% avg (3 tservers) | 400% per node | 45% | No |
| Node CPU total | 73-85% | 100% | 73-85% | No |
| Memory | 1,271 MB | 8,192 MB | 16% | No |
| Network | 3.2 MB/s RX, 3.0 TX | — | Low | No |
| WAL sync rate | 7.1 ops/s per tserver | — | — | No |
| Transaction conflicts | 0/s | — | — | N/A |

## Node CPU Breakdown (mid-run, Prometheus)

| Node | User | System | IOWait | Steal | SoftIRQ | Total |
|------|------|--------|--------|-------|---------|-------|
| worker-1 | 47.1% | 19.0% | 3.7% | 8.4% | 6.8% | ~85% |
| worker-2 | 39.8% | 17.1% | 6.2% | 8.1% | 6.1% | ~77% |
| worker-3 | 36.3% | 15.0% | 7.3% | 8.7% | 5.2% | ~73% |

## Write Path Metrics (mid-run, Prometheus)

| tserver | Write RPC latency | Write RPC rate | WAL sync latency | WAL sync rate | WAL bytes |
|---------|------------------|----------------|-----------------|---------------|-----------|
| yb-tserver-0 | 6.79 ms | 723 ops/s | 63.51 ms | 7.3/s | 1,445 KB/s |
| yb-tserver-1 | 8.47 ms | 807 ops/s | 63.52 ms | 7.1/s | 1,389 KB/s |
| yb-tserver-2 | 6.61 ms | 776 ops/s | 90.86 ms | 6.8/s | 1,342 KB/s |

Total write RPC rate: ~2,307 ops/s across cluster.

## Raft Consensus (mid-run, Prometheus)

| tserver | UpdateConsensus latency | Rate |
|---------|------------------------|------|
| yb-tserver-0 | 0.77 ms | 2,952 ops/s |
| yb-tserver-1 | 1.15 ms | 2,159 ops/s |
| yb-tserver-2 | 0.79 ms | 2,545 ops/s |

## Bottleneck: Per-Insert Latency (Not Resource Saturation)

No resource is saturated. The system is **latency-bound** on the per-insert write path:

1. Each insert requires a write RPC (~7ms avg) which includes Raft consensus replication
2. With 48 threads and ~7ms per write, theoretical max ≈ 48 × (1000/7) ≈ 6,857 ops/s
3. Actual TPS is 1,836 — lower than theoretical because each insert involves multiple internal operations (intents, transaction coordination, multiple tablets for secondary indexes)
4. The WAL sync (64-91ms) runs in background every 5s and doesn't block the write path

## Comparison: oltp_insert vs oltp_read_write

| Metric | oltp_read_write (48t, triggers) | oltp_insert (48t, no triggers) |
|--------|-------------------------------|-------------------------------|
| TPS | 41.2 | **1,835.7** (44x) |
| QPS | 2,025 | 1,836 |
| Errors/s | 5.30 | **0** |
| Error % | 12.9% | **0%** |
| p95 | 2,009 ms | **37.6 ms** |
| Container CPU | — | 178% |
| Node CPU | — | 73-85% |

The 44x TPS difference comes from:
- oltp_read_write: 41 writes + 2 reads per transaction + trigger overhead (SELECT + DELETE per write) + row contention
- oltp_insert: 1 insert per transaction, no contention, no trigger

This baseline establishes the insert throughput ceiling for this cluster configuration.
