# Bottleneck Analysis: Write-Heavy Workload

**Report:** 20260327_1304
**Config:** dm-delay=1ms, IOPS cap=500, 3 tservers (4 CPU / 8 GB each), 24 threads
**Workload:** oltp_read_write, write-heavy (2 point_selects, 20 index_updates, 20 non_index_updates, 10 rows/insert)

## Summary

| Metric | Value |
|--------|-------|
| TPS | 58.22 |
| QPS | 2,731.94 |
| p95 Latency | 549.52 ms |
| Avg Latency | 412.39 ms |
| Errors/s | 2.17 |

## Bottleneck: Raft WAL Sync Latency

The primary bottleneck is **Raft WAL sync latency**, measured at ~10.4 ms per sync across all tservers.

### Evidence

#### 1. WAL log_sync dominates write latency

| Metric (Prometheus) | tserver-0 | tserver-1 | tserver-2 |
|---------------------|-----------|-----------|-----------|
| `log_sync_latency` avg | 10.4 ms | 10.6 ms | 10.8 ms |
| `log_sync` rate | 1.6 ops/s/tablet | 1.6 ops/s/tablet | 1.6 ops/s/tablet |
| `log_append_latency` avg | 0.07 ms | 0.08 ms | 0.08 ms |
| `log_group_commit_latency` avg | 0.10 ms | 0.11 ms | 0.11 ms |

- `log_sync_latency` (Raft WAL fsync) is 10.4 ms — this is the time to persist consensus entries to disk.
- `log_append_latency` (in-memory append) is 0.07 ms — negligible.
- `log_group_commit_latency` (batching overhead) is 0.10 ms — negligible.
- The WAL sync accounts for >99% of the Raft log write path.

#### 2. Write RPCs are 17x slower than Read RPCs

| Metric (Prometheus) | tserver-0 | tserver-1 | tserver-2 |
|---------------------|-----------|-----------|-----------|
| `TabletServerService_Write` avg latency | 3.34 ms | 3.83 ms | 3.51 ms |
| `TabletServerService_Read` avg latency | 0.20 ms | 0.20 ms | 0.23 ms |
| `TabletServerService_Write` rate | 1,128 ops/s | 1,515 ops/s | 1,160 ops/s |

- Per-RPC write latency is 3.5 ms avg. With 41 writes per transaction spread across multiple tablets, the transaction accumulates multiple sequential write RPCs.
- Total write RPC rate across cluster: ~3,803 ops/s.

#### 3. Consensus replication is fast

| Metric (Prometheus) | tserver-0 | tserver-1 | tserver-2 |
|---------------------|-----------|-----------|-----------|
| `ConsensusService_UpdateConsensus` avg latency | 0.38 ms | 0.45 ms | 0.44 ms |
| `ConsensusService_UpdateConsensus` rate | 3,690 ops/s | 3,093 ops/s | 3,410 ops/s |

- Inter-node Raft replication RPCs are 0.4 ms — network is not a bottleneck.

### What is NOT the bottleneck

| Resource | Measured | Capacity | Utilization | Bottleneck? |
|----------|----------|----------|-------------|-------------|
| Disk Write IOPS | avg 75, max 100 | 500 (cap) | 15-20% | No |
| Container CPU | 152% | 400% (4 cores) | 38% | No |
| Node CPU total | 62% avg | 100% | 62% | No |
| Node CPU iowait | 2.7% | — | Low | No |
| Node CPU steal | 6.2% | — | Moderate | No |
| Memory | 1,508 MB | 8,192 MB | 18% | No |
| Network | 2.6 MB/s RX+TX | — | Low | No |
| RocksDB WAL syncs | 0 ops/s | — | None during test | No |
| Transaction conflicts | ~0.2/s per tserver | — | Low | No |
| WAL bytes logged | ~65 KB/s per tserver | — | Low | No |

### Comparison: Write-Heavy vs Balanced (same 24 threads)

| Metric | Balanced (10r/31w) | Write-Heavy (2r/41w) | Change |
|--------|-------------------|---------------------|--------|
| TPS | 99.2 | 58.2 | -41% |
| QPS | 3,392 | 2,732 | -19% |
| p95 Latency | 314 ms | 550 ms | +75% |
| Container CPU | 193.6% | 152.0% | -21% |
| Disk Write IOPS | 86 | 75 | -13% |

- TPS dropped 41% while CPU dropped 21% — threads are spending more time blocked on I/O waits, not doing compute.
- Disk IOPS actually decreased slightly — the bottleneck is per-I/O latency (dm-delay), not throughput capacity.

### Mechanism

Each write transaction follows this path:
1. Client sends write operations to tserver (write RPC: 3.5 ms each)
2. Tserver leader appends to Raft WAL (`log_append`: 0.07 ms)
3. Raft WAL syncs to disk (`log_sync`: **10.4 ms** — includes 1ms dm-delay)
4. Leader sends `UpdateConsensus` to followers (0.4 ms network)
5. Followers sync their WAL to disk (**10.4 ms**)
6. Leader commits after majority acknowledgment

With 41 writes per transaction across multiple tablets, steps 1-6 repeat for each tablet involved. The 10.4 ms WAL sync on each node is the serialization point that limits throughput.
