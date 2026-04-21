# k3s-virsh 2-vCPU Memory Tuning Analysis (2026-04-21)

## Infrastructure

- 3 tserver nodes: 2 vCPU / 8 GB RAM each (1:4 CPU:memory ratio)
- 3 masters on control node
- RF=3, 2 tablets per tserver, `durable_wal_write=false` (WAL buffered)
- Workload: `oltp_insert` (1 INSERT per txn, SERIAL PK, trigger-based)

## Baseline Results (default gflags)

| Threads | TPS | p95 (ms) | CPU/node (cores) | CPU util | Mem (MB) | WrIOPS | Report |
|---------|-----|----------|-------------------|----------|----------|--------|--------|
| 1       | 260 | 5.1      | 0.88              | 44%      | 3,022    | 39     | 20260421_1927 |
| 2       | 325 | 8.6      | 1.24              | 62%      | 3,729    | 27     | 20260421_2314 |
| 5       | 445 | 17.3     | 1.68              | 84%      | 3,448    | 52     | 20260421_2305 |
| 6       | 495 | 18.6     | 1.75              | 87%      | 3,268    | 49     | 20260421_1932 |

## Tuned Results

**Changes:** `global_memstore_size_percentage=25` (from 10%), `rocksdb_max_background_compactions=1` (from default 3)

| Threads | TPS | p95 (ms) | CPU/node (cores) | CPU util | Mem (MB) | WrIOPS | Report |
|---------|-----|----------|-------------------|----------|----------|--------|--------|
| 2       | 529 | 4.9      | 1.39              | 70%      | 3,444    | 30     | 20260421_2332 |

### Comparison at 2 threads

| Metric            | Baseline | Tuned   | Change  |
|-------------------|----------|---------|---------|
| TPS               | 325      | 529     | **+63%** |
| p95 latency       | 8.6 ms   | 4.9 ms  | **-43%** |
| CPU/node          | 1.24 cr  | 1.39 cr | +12%    |
| CPU utilization   | 62%      | 70%     | +8pp    |
| Memory            | 3,729 MB | 3,444 MB| -8%     |
| Write IOPS        | 27       | 30      | +11%    |
| TPS per CPU-core  | 262      | 381     | **+45%** |

## Observations

### Scaling efficiency (baseline)

- 1→2 threads: +25% TPS, +41% CPU — **poor scaling**. p95 jumps from 5→9ms.
- 2→5 threads: +37% TPS, +35% CPU — linear. p95 rises to 17ms.
- 5→6 threads: +11% TPS, +4% CPU — near saturation (87% util).
- TPS/core degrades: 296 (1t) → 262 (2t) → 265 (5t) → 283 (6t).

The 1→2 thread anomaly was the key signal: adding 1 thread should double TPS if resources aren't constrained, but we only gained 25% despite having 38% CPU headroom. This suggested per-transaction CPU overhead was too high.

### Tuning impact

At 2 threads, the tuned config achieves **higher TPS than the 5-thread baseline** (529 vs 445) while using **less CPU** (1.39 vs 1.68 cores). The efficiency gain is dramatic:

- **TPS per CPU-core: 381 (tuned 2t) vs 262 (baseline 2t)** — 45% more efficient
- Tuned 2t now matches what would've required ~4 threads under baseline config

## Analysis Methodology

### Step 1: Identify the bottleneck

Queried Prometheus for per-transaction latency breakdown across the YugabyteDB write path. All metrics are per-tserver averages using `irate(...[60s])` over the steady-state window (post-warmup).

**Metrics queried and results (2-thread baseline):**

| Metric | PromQL pattern | Result | Interpretation |
|--------|---------------|--------|----------------|
| `handler_latency_yb_tserver_TabletServerService_Write` | sum/count ratio, `{job="yb-tserver"}` | 585-777 us | Total Write RPC time on tablet |
| `handler_latency_yb_tserver_TabletServerService_UpdateTransaction` | sum/count ratio | 370-490 us | 2PC coordinator overhead |
| `handler_latency_yb_tserver_TabletServerService_Read` | sum/count ratio | 83-93 us | Trigger SELECT (fast) |
| `handler_latency_yb_consensus_ConsensusService_UpdateConsensus` | sum/count ratio | 84-149 us | Raft replication |
| `log_sync_latency` | per-tablet sum/count | 1800-3000 us | WAL fsync (background, not per-txn) |
| `log_group_commit_latency` | per-tablet sum/count | 25-40 us | WAL group commit (in-memory) |
| `rocksdb_db_write_micros` | per-tablet sum/count | 20-32 us | RocksDB memtable insert |
| `ql_write_latency` | per-tablet sum/count | 550-780 us | SQL-layer write processing |
| `write_lock_latency` | per-tablet sum/count | ~1 us | Row-level lock acquisition |
| `rpc_incoming_queue_time` | avg | 42 us | No RPC queuing |
| `rocksdb_block_cache_hit` / `_miss` | sum irate | 1837 / 8 per sec | 99.6% cache hit rate |
| `node_cpu_seconds_total{mode=...}` | per-mode breakdown | user:0.23-0.52, sys:0.15-0.22, iowait:0 | CPU-bound, not IO-bound |
| `node_disk_write_time_seconds_total` | per-device ratio | 0.65-0.76 ms/op | Disk latency acceptable |

### Step 2: Rule out non-CPU bottlenecks

- **Disk I/O**: Zero iowait, WAL is buffered (`durable_wal_write=false`), write IOPS ~30 per node.
- **Network**: 2-4 MB/s per node, well under limits.
- **Lock contention**: write_lock_latency ~1us at 2 threads — no contention.
- **RPC queuing**: 42us queue time — no saturation.
- **Block cache**: 99.6% hit rate — reads are cached.

### Step 3: Identify CPU waste

With CPU being the constraining resource, we looked for background work consuming CPU unnecessarily:

1. **RocksDB compactions**: Default `rocksdb_max_background_compactions=3` means up to 3 compaction threads per tserver competing for 2 vCPUs. Each compaction reads+writes SST files, consuming CPU for decompression/compression.

2. **Memstore flushes**: Default `global_memstore_size_percentage=10` (~200MB on 2GB) means frequent flushing to SST files, which triggers more compactions. On 8GB nodes, this is wastefully conservative.

### Step 4: Apply tuning

- **`global_memstore_size_percentage=25`**: With 8GB RAM available, increase in-memory buffer from ~200MB to ~500MB+. Fewer flushes → fewer SST files → fewer compactions → less background CPU.
- **`rocksdb_max_background_compactions=1`**: Limit compaction parallelism from 3 to 1 thread. On 2-vCPU nodes, 3 concurrent compaction threads steal too many cycles from foreground write processing.

### Why this works

The tuning reduced **background CPU consumption** (compaction threads), freeing cycles for **foreground write processing**. The result: each INSERT completes faster (4.9ms vs 8.6ms at p95), so the 2 client threads can issue more transactions per second.

The memory increase didn't help via caching (already 99.6% hit rate) — it helped by **reducing write amplification**: larger memstore → fewer flushes → fewer L0 files → fewer compactions → less CPU wasted on background work.

## Next Steps

- Run tuned config at higher thread counts (5, 6) to see if the efficiency gain holds under saturation
- Test `db_block_cache_size_bytes` increase (currently default ~1GB, could use 2-3GB of the available 8GB)
- Profile whether `rocksdb_max_background_compactions=1` causes L0 stall under sustained write load
