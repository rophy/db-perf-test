# Bottleneck Analysis: WAL Sync Interval Tuning (5s)

**Report:** 20260327_2310
**Config:** dm-delay=5ms, IOPS cap=80, 3 tservers (2 vCPU pinned), 24 threads
**Tuning:** `bytes_durable_wal_write_mb=4`, `interval_durable_wal_write_ms=5000`
**Workload:** oltp_read_write, write-heavy + trigger (cleanup_duplicate_k)

## Summary

| Metric | Value |
|--------|-------|
| TPS | 23.26 |
| QPS | 1,107.18 |
| p95 Latency | 1,506 ms |
| Avg Latency | 1,032 ms |
| Errors/s | 1.59 |

## Effect of Tuning: `interval_durable_wal_write_ms` 1000 → 5000

All three runs: same cluster, same trigger, same workload. Only WAL sync thresholds changed.

| Metric | Default (1MB/1s) | 4MB/1s | **4MB/5s** |
|--------|-----------------|--------|-----------|
| **TPS** | 17.50 | 18.00 | **23.26** |
| QPS | 836 | 859 | **1,107** |
| p95 Latency | 2,279 ms | 1,973 ms | **1,506 ms** |
| WAL sync rate | 29 ops/s | 28 ops/s | **6.4 ops/s** |
| WAL sync latency | 145 ms | 157 ms | **69 ms** |
| Disk Write IOPS | 84 | 14 | **4** |
| iowait avg | 16.5% | ~24% | **2.3%** |
| Node CPU avg | 95-98% | 95-98% | **77-96%** |

### What worked

Increasing `interval_durable_wal_write_ms` from 1000 to 5000 was the effective change:

1. **WAL sync rate dropped 78%** (29 → 6.4 ops/s) — each tablet now syncs every ~5s instead of ~1s
2. **IOPS dropped 95%** (84 → 4) — far below the 80 cap, eliminating I/O queueing
3. **iowait dropped 85%** (16.5% → 2.3%) — threads no longer blocked on disk
4. **WAL sync latency dropped 52%** (145 → 69ms) — no queueing delay, just the actual dm-delay cost
5. **TPS improved 33%** (17.5 → 23.3) — freed CPU from I/O wait enabled more throughput

### Why `bytes_durable_wal_write_mb=4` alone didn't help

At ~250 KB/s WAL write rate per tserver, accumulating 1MB takes ~4 seconds. The 1-second time-based threshold (`interval_durable_wal_write_ms=1000`) always fired first, making the data threshold irrelevant. Increasing the data threshold from 1MB to 4MB had no measurable effect because the timer was the dominant trigger.

### Evidence from Prometheus (mid-run)

#### WAL sync metrics

| tserver | Sync latency | Sync rate | WAL bytes |
|---------|-------------|-----------|-----------|
| yb-tserver-0 | 58.64 ms | 6.1 ops/s | 282 KB/s |
| yb-tserver-1 | 87.58 ms | 6.4 ops/s | 283 KB/s |
| yb-tserver-2 | 59.63 ms | 6.8 ops/s | 300 KB/s |

#### Node CPU breakdown

| Node | CPU total | iowait | steal |
|------|-----------|--------|-------|
| ygdb-worker-1 | 95.5% | 1.3% | — |
| ygdb-worker-2 | 76.6% | 6.2% | — |
| ygdb-worker-3 | 84.7% | 3.2% | — |

Report-period averages: user 30.7%, system 11.5%, iowait 2.3%, steal 3.3%, softirq 6.4%

### Remaining bottleneck

Worker-1 is still at 95.5% CPU. The system has shifted from **IOPS-bound** back to **CPU-bound**. Further improvement would require either:
- More CPU per worker (more vCPUs)
- Reducing per-transaction CPU cost (optimize trigger function, reduce operations per transaction)
- Enabling `multi_raft_batch_size` to save CPU on Raft RPC overhead

### Durability tradeoff

With `interval_durable_wal_write_ms=5000`, up to 5 seconds of WAL data may be unsynced to disk on each node at any time. This data is still:
- In the OS page cache (survives process crash)
- Replicated to 2 other nodes via Raft (survives single node failure)

Data loss only occurs if all 3 nodes lose power simultaneously within the 5-second window — an extremely unlikely scenario for an RF=3 cluster.
