# Analysis: interval_durable_wal_write_ms = 10000 vs 5000

Same apples-to-apples lab as `20260414_2205`, changing only the WAL time threshold from 5 s to 10 s. All other knobs identical (dm-delay=5ms, IOPS=80, 4 vCPU pinned 1:1 to 2 P-cores per worker, 512 threads, oltp_insert + `cleanup_duplicate_k` triggers, `bytes_durable_wal_write_mb=4`, `durable_wal_write=false`, `oracle-rac-vm` shut down).

## End-to-End Results

| Metric | interval=5000 (20260414_2205) | interval=10000 (this) | Delta |
|---|---|---|---|
| TPS | 2,005.17 | 2,003.70 | ~0 |
| p95 latency | 427.07 ms | 419.45 ms | ~0 |
| Errors | 0 | 0 | — |
| Tserver CPU (sum) | 193.6% | 197.2% | — |
| Tserver memory (sum) | 2,351 MB | 2,948 MB | **+597 MB (+25%)** |
| Cluster disk write IOPS | 50 | 46 | −8% |
| Worker iowait | 4.0% | 5.1% | — |

Client-visible throughput and latency are unchanged. The interval change does not affect TPS at this workload because neither run is disk-limited.

## Prometheus Breakdown of WAL Activity

Queried over the full 150 s run window:

| Metric | interval=5000 | interval=10000 | Ratio |
|---|---|---|---|
| Cluster WAL fsyncs/s | 32.85 | 16.29 | **0.50×** |
| WAL fsyncs/s per tserver | 10.75 | 5.30 | 0.49× |
| WAL bytes/s per tserver | 2,489 KB | 2,430 KB | 0.98× |
| log_append rate per tserver | 5,168/s | 5,043/s | 0.98× |
| Avg bytes per fsync | 232 KB | 458 KB | 1.97× |
| RocksDB flush KB/s (cluster) | 2,203 | 2,323 | 1.05× |

## What This Confirms

1. **The per-peer × interval theory holds exactly for WAL fsyncs.** With ~50 tablet peers per tserver and a 5 s time threshold, expected rate = `50 / 5 = 10 fsyncs/s`; measured 10.75. Doubling the interval to 10 s drops it to 5.3/s — clean 2× reduction.
2. **The size threshold (4 MB) is not firing** at this workload. Each peer writes roughly 2,430 KB/s ÷ 50 peers ≈ 48 KB/s. Over a 10 s interval that accumulates ~480 KB per peer — well under 4 MB. The time threshold owns the fsync cadence entirely.
3. **WAL is not the dominant write-IOPS source.** WAL fsyncs dropped by ~16/s cluster-wide (32.85 → 16.29), but total block-layer write IOPS only dropped 4 (50 → 46). The remaining ~30 IOPS come from RocksDB memtable flushes (~2.2 MB/s) and metadata writes, which are unaffected by the WAL interval.

## What This Rules Out

- Raising `bytes_durable_wal_write_mb` alone will not reduce IOPS — size is never the firing threshold here.
- Raising `interval_durable_wal_write_ms` past some point yields diminishing returns on total IOPS, because non-WAL writes dominate.

## Cost of the Change

The +597 MB memory growth is the notable trade-off. Per-tserver extra WAL buffering explains at most ~48 KB/s × 10 s × 50 peers ≈ 24 MB per tserver (72 MB cluster) — nowhere near 597 MB. The bulk of the memory increase is therefore not WAL buffers. Likely candidates: larger RocksDB memtables (because flush pressure rose 5%), or higher postgres backend memory from longer-held connection state. A per-metric memory breakdown would be needed to confirm.

## Practical Implication

To reduce disk write IOPS materially on this workload, the lever is RocksDB, not WAL. Useful follow-ups:

- Increase `memstore_size_mb` / `global_memstore_size_percentage` — delays SST flushes, batching more writes per flush.
- Reduce the number of tablets (e.g. `ysql_num_shards_per_tserver=1`) — halves the RocksDB bookkeeping and the WAL peer count simultaneously.
- If WAL fsyncs specifically need to approach zero, the `interval_durable_wal_write_ms` knob continues to work linearly, but the payoff in total IOPS is small past ~10 s given the RocksDB floor.

Raw Prometheus queries used:
```promql
sum by (exported_instance) (rate(log_sync_latency_count[150s]))
sum by (exported_instance) (rate(log_bytes_logged[150s]))/1024
sum by (exported_instance) (rate(log_append_latency_count[150s]))
sum(rate(rocksdb_flush_write_bytes[150s]))/1024
```
