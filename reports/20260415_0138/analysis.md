# Session Re-Analysis: RocksDB IOPS Tuning (Clean Data)

Supersedes `reports/20260414_2352/analysis.md`, which was invalidated by a methodology error (no `sysbench-cleanup` + `sysbench-prepare` between runs, so row counts drifted and per-op cost crept up across experiments).

This re-run resets the tables to a fresh 10 × 100,000 layout and re-installs the `cleanup_duplicate_k` trigger before every experiment. Each experiment uses a freshly deployed tserver (gflag changes require pod restart) and the same 30 s warmup + 120 s measure.

All other conditions identical to the prior session: k3s-virsh lab, 3 workers (4 vCPU, 8 GB, 2 P-cores pinned each), RF=3, dm-delay=5 ms, IOPS cap=80, 512 sysbench threads, oltp_insert with `cleanup_duplicate_k` trigger, `bytes_durable_wal_write_mb=4`, `interval_durable_wal_write_ms=10000` held constant across all runs.

## Results

| # | Config change | TPS | p95 (ms) | Write IOPS | Read IOPS | Mem (MB) | iowait | Errors |
|---|---|---|---|---|---|---|---|---|
| 1 | baseline (interval=10 s, defaults) | 1,855 | 484 | 42 | 0 | 2,258 | 3.5% | 0 |
| 2 | `memstore_size_mb=512` | 1,828 | 467 | 41 | 0 | 2,307 | 3.2% | 0 |
| 3 | + `global_memstore_size_percentage=40` | **1,890** | **451** | **40** | 0 | 2,608 | 3.9% | 0 |
| 4 | `rocksdb_compact_flush_rate_limit_bytes_per_sec=2 MB/s` | 1,834 | 459 | 51 | 0 | 2,459 | 4.4% | 0 |
| 5 | rate_limit=20 MB/s | 1,816 | 476 | 41 | 0 | 2,374 | 4.4% | 0 |
| 6 | rate_limit=100 MB/s | 1,799 | 493 | 44 | 1 | 2,371 | 4.8% | 0 |
| 7 | `rocksdb_disable_compactions=true` | 1,833 | 459 | 40 | 0 | 2,417 | 4.3% | 0 |
| 8 | `compression_type=Zlib` | 1,765 | 502 | 40 | 0 | 2,499 | 4.4% | 0 |

Run folders: `20260415_0039` through `20260415_0138`, labeled via `EXPERIMENT_LABEL.txt`.

## What the Clean Data Overturns

The prior analysis made three strong claims. Each of them was a contamination artifact.

### ❌ "rocksdb_compact_flush_rate_limit_bytes_per_sec at 2 or 20 MB/s crashes the cluster"

On clean data, rate_limit=2 MB/s ran to completion with TPS 1,834 (−1%) and 0 errors. The earlier crash was the **cluster** failing at low throughput, not the gflag at issue. Row count drift + trigger overhead on bloated tables had already pushed the cluster near the edge before the gflag was even applied.

### ❌ "Zlib compression crashes the benchmark due to CPU load"

On clean data, Zlib ran to completion with TPS 1,765 (−5%) and 0 errors. It is the slowest config measured but not remotely close to crashing. Earlier "crash" was again cluster state, not CPU saturation from Zlib.

### ❌ "~28 of 46 write IOPS (60%) are compaction-driven"

The disable_compactions run here shows **Write IOPS 40 vs baseline 42** — essentially no change. The 28-IOPS figure from the contaminated session came from a run where the database had grown large enough to actually need compaction, and compactions were blocked → SST accumulation → read-amp spiral → stalls → apparent "write IOPS dropped". On a 2-minute run over 10 × 100,000 rows, **there is no steady-state compaction to disable**; the per-tserver flush volume over the measurement window isn't enough to trigger the first compaction round under Universal compaction (`level0_file_num_compaction_trigger=5`). So the "compaction share of IOPS" number from the prior analysis is not trustworthy at this workload scale.

## What the Clean Data Confirms

### ✅ RocksDB tuning knobs barely move IOPS on this workload

All 8 runs produce Write IOPS in [40, 51] and TPS in [1,765, 1,890]. That's roughly ±5% variance across every tuning axis tested — indistinguishable from run-to-run noise for most configurations. The only modest outliers:

- `rate_limit=2 MB/s` bumped IOPS to 51 (+21% vs baseline). The rate limiter batching behavior appears to slightly *increase* IOPS at this cap, not decrease it. Not harmful to TPS, but it's the opposite of the intended effect.
- `memstore=512 + global=40%` actually slightly outperformed baseline (+2% TPS, −5% IOPS). This contradicts the prior analysis's claim that bigger memtables hurt under Universal compaction — that claim was also contamination. On this workload/duration, bigger memtables produce a small net win.

### ✅ The "WAL trades memory for IOPS, RocksDB doesn't" asymmetry still holds, but for a different reason than originally argued

- The prior session measured WAL fsync tuning (`interval_durable_wal_write_ms` 5s → 10s) cutting cluster fsyncs 2× — that measurement was done earlier and on the same data, but was comparing matched pairs and the measurement is direct (Prometheus counter), so it remains valid.
- RocksDB tuning on this short workload doesn't move IOPS because **compaction isn't the dominant IOPS source at this scale** — WAL fsyncs + memtable flushes are, and those aren't bounded by memstore size.
- The "Universal Compaction rewrites big sorted runs" theory from the prior subagent research is still correct in principle, but it doesn't manifest in this 2-minute benchmark because compactions barely run. A longer-duration test (e.g. 30 min with continuous ingest) would be needed to observe the LSM-scaling effects.

## Revised IOPS Attribution

We cannot cleanly attribute the baseline 42 write IOPS between WAL and RocksDB on this run because:
- disable_compactions produced the same IOPS (40 ≈ 42).
- That means in the measured 2-min window, compaction contributes ≤2 IOPS.
- The remaining ~40 IOPS is WAL fsync + memtable flush — both unavoidable at this ingest rate.

To resolve the compaction share, we'd need a workload that runs long enough for the LSM to reach steady state (multiple compaction rounds per tablet). This benchmark doesn't do that.

## Methodology Lesson (Committed to CLAUDE.md)

`sysbench-cleanup` + `sysbench-prepare` must run **between every run whose results will be compared**. sysbench `oltp_insert` appends rows; back-to-back runs without reset grow tables by tens of thousands of rows per run. The `cleanup_duplicate_k` trigger's SELECT-before-INSERT slows as tables grow, so TPS drifts downward run-over-run even with identical configs. This drift is enough to (a) make a cluster near capacity cross into crash territory mid-experiment and (b) shift attribution numbers in ways that flip conclusions.

Four contaminated runs in the prior session crashed not because of the gflag under test but because the cumulative drift had degraded the cluster. Those runs shouldn't have been interpreted as "X crashes the cluster" — the cluster was already compromised.

## Practical Takeaways

1. On this workload (2 min, 10 × 100K rows, 512 threads, dm-delay=5 ms, IOPS cap=80), Write IOPS is ~42 and largely invariant to RocksDB tuning. WAL tuning moves it meaningfully; RocksDB tuning does not.
2. The only gflag that measurably reduced IOPS was `memstore + global_memstore` (42 → 40), and even that is small and within noise.
3. `compression_type=Zlib` costs ~5% TPS without a clear IOPS benefit at this scale. LZ4 was not tested this round and remains an option if a CPU-for-IOPS trade is desired.
4. To actually observe RocksDB's tuning effects on IOPS, the benchmark needs to run long enough for multiple compaction rounds. Consider a 15-30 min variant for a follow-up session.
