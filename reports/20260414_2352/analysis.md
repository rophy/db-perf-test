> **INVALID — METHODOLOGY ERROR.** No `sysbench-cleanup` + `sysbench-prepare` was
> run between the 7 experiments in this analysis. Row counts grew monotonically
> across runs (sbtest1 drifted from 100K → 136K+). The trigger's
> SELECT-before-INSERT slows as tables grow, so per-op cost drifted and TPS
> numbers across runs are not comparable. Crash attributions (Zlib, rate-limit,
> disable_compactions) may also be contaminated — a clean baseline re-run with
> the same config subsequently failed the same way, proving the cluster state
> was the fault, not the gflag under test. All conclusions below must be
> re-validated on freshly-prepared tables. A fresh re-run is underway; see the
> next analysis folder for valid numbers.

# Session Analysis: Can RocksDB Trade Memory/CPU for IOPS Like WAL Can?

Spans runs `20260414_2225` (baseline) through `20260414_2352` (disable_compactions). All runs on the same k3s-virsh lab: 3 workers (4 vCPU, 8 GB, 2 P-cores pinned each), RF=3, sysbench oltp_insert + `cleanup_duplicate_k` trigger, 512 threads, 150 s window (30 s warmup + 120 s measure), dm-delay=5 ms, IOPS cap=80.

## Motivating Question

WAL tuning via `interval_durable_wal_write_ms` cleanly reduces fsyncs — doubling the interval halves the fsync rate (`20260414_2225` analysis). Does RocksDB have an equivalent memory-for-IOPS trade? If we give RocksDB bigger memtables, fewer/larger compactions, or rate-limited background writes, does total write IOPS drop proportionally?

## Runs

| Run | Config change vs baseline | TPS | p95 (ms) | Write IOPS | Read IOPS | iowait | Outcome |
|---|---|---|---|---|---|---|---|
| 20260414_2225 | baseline (interval=10s) | 2,004 | 419 | 46 | 0 | 5.1% | ok |
| 20260414_2255 | `memstore_size_mb=512` (cold cache) | 1,875 | 467 | 41 | 0 | 3.8% | ok |
| 20260414_2307 | `memstore_size_mb=512` (warm cache) | 1,854 | 476 | 55 | 11 | 1.7% | ok |
| 20260414_2314 | + `global_memstore_size_percentage=40` | 1,619 | 451 | 42 | 21 | 10.2% | ok |
| 20260414_2327 | `rocksdb_compact_flush_rate_limit_bytes_per_sec=2 MB/s` | — | — | 21 | 45 | 25.3% | **crashed** |
| 20260414_2337 | rate_limit=20 MB/s | — | — | 11 | 4 | 19.0% | **crashed** |
| 20260414_2348 | rate_limit=100 MB/s | 1,254 | 646 | 30 | 43 | 12.8% | completed but degraded |
| 20260414_2352 | `rocksdb_disable_compactions=true` | — | — | 18 | 15 | 22.6% | **crashed (used for floor measurement)** |

All other gflags and workload held constant.

## Answer: No, RocksDB does not offer a memory-for-IOPS trade like WAL does

### The WAL path (for contrast)

- Append-only, single-write. Each byte hits disk exactly once.
- `interval_durable_wal_write_ms` buffers dirty pages in **kernel page cache** until the timer fires, then fsyncs once. No userspace buffer growth (verified in YB source: `src/yb/consensus/log.cc:1290-1331` — bytes are already `write()`-ed to the segment file; the gflag only gates `fsync()`).
- At our workload, doubling the interval (5 s → 10 s) cut cluster WAL fsyncs 32.85 → 16.29/s — a clean 2× (measured in 20260414_2225 analysis).
- Cost: larger kernel page-cache residency per peer × 3 replicas × ~50 peers per tserver. Container memory rose ~597 MB across the cluster between the 5 s and 10 s runs, consistent with dirty-page accumulation.

### The RocksDB path

YB configures **Universal Compaction with `num_levels=1`** (`src/yb/docdb/docdb_rocksdb_util.cc:690-714`). Under Universal:

- Every byte flushed goes through `ingest → L0 SST → compaction → bigger SST → compaction → ...`.
- Steady-state write amplification is roughly `log_{size_ratio}(DB_size / flush_unit)` — typically 3–10×.
- **The total bytes written per byte ingested is set by LSM structure, not buffer size.** Delaying flushes doesn't remove the writes; it redistributes them into burstier, larger compactions.

Every lever we tried confirms this.

#### Lever 1: Bigger memtables (`memstore_size_mb=128 → 512`)

- TPS dropped 6% (2,004 → 1,854); write IOPS barely moved (46 → 55).
- Cold vs warm cache made no meaningful difference (runs 2255 vs 2307), so it's not a startup artifact.
- Each flush now produces ~4× larger L0 SSTs. Compaction inputs grew past page-cache working set, so compaction reads started hitting the disk: Read IOPS 0 → 11.

#### Lever 2: Larger per-tserver memtable budget (`global_memstore_size_percentage=10 → 40`)

- TPS dropped a further 13% (1,854 → 1,619). Write IOPS unchanged (42); **Read IOPS doubled (11 → 21)**; iowait doubled (1.7% → 10.2%).
- With 4× more dirty data across all tablets, flushes synchronize into storms. The resulting bigger SSTs cost more to read-merge during compaction. Total IOPS went **up** (63 vs 46 baseline).

#### Lever 3: Compaction+flush rate limiting (`rocksdb_compact_flush_rate_limit_bytes_per_sec`)

- 2 MB/s and 20 MB/s caps crashed the benchmark within 60 seconds with `UpdateTransaction RPC ... timed out` errors. Transaction-status tablets starve on the shared limiter; RAFT deadlines expire, cascading leadership failures.
- 100 MB/s (≈50× observed baseline flush rate) completed but degraded: TPS −37%, total IOPS +59% (73 vs 46). The limiter alters compaction timing in ways that produce burstier read+write patterns.
- Verdict: this gflag is designed to throttle bulk-ingest background I/O, not reduce steady-state IOPS. It cannot be tuned below the workload's natural rate without triggering write stalls.

#### Lever 4: Disable compactions entirely (`rocksdb_disable_compactions=true`, 20260414_2352)

Intended as a floor measurement, crashed as expected. Useful data anyway:

- **Write IOPS dropped 46 → 18.** That's direct measured evidence: ~28 of the 46 baseline write IOPS (60%) are compaction-driven. The WAL+flush-only floor is ~18 IOPS.
- **Read IOPS appeared (0 → 15)** because the trigger's SELECT-before-INSERT probes every un-merged L0 file.
- **Benchmark crashed via write throttling** at `sst_files_soft_limit=24` (`src/yb/tserver/service_util.cc:49`). Hot transaction-status tablets accumulate L0 fastest and hit the limit first.

This confirms RocksDB *must* compact for the system to function; the compaction IOPS aren't optional overhead.

## IOPS Attribution — Measured, Not Assumed

The disable_compactions run gives us the first direct measurement of the compaction share of write IOPS:

| Component | IOPS (cluster, write) | Method |
|---|---|---|
| WAL fsync | ~16 | Prometheus `log_sync_latency_count` rate |
| RocksDB flush | ~2 | inferred: disable_compactions floor (18) − WAL fsyncs (16) |
| RocksDB compaction | ~28 | 46 baseline − 18 disable_compactions |
| **Total** | **46** | node_exporter block-layer write IOPS |

Prior attribution claims in analysis reports were inference from subtraction of direct metrics (WAL fsync rate, flush bytes/s). This run is the first load-bearing measurement for compaction attribution.

Caveats:
- Each WAL fsync may translate to more than 1 block-layer IOP. The counts above assume ~1:1, which this data roughly corroborates but doesn't prove.
- Disable-compactions mode may change flush patterns (e.g. flushes under throttle vs. free-flowing). Treat ±3 IOPS as uncertainty.

## Conclusion

Yes — we can conclude that **RocksDB cannot trade CPU/memory for IOPS the way WAL can.**

- WAL: single-write, one fsync per interval → buffering scales memory linearly with interval and cuts IOPS linearly with interval.
- RocksDB: multi-write (LSM write-amp), bytes-to-disk is a property of the tree structure and workload ingest rate, not the memtable size. Enlarging buffers shifts the write timing and often adds read IOPS (compaction inputs exceed page cache) without reducing total I/O.

The only remaining gflag-only lever we haven't exhausted is **compression** (Snappy → LZ4 or Zlib) — a CPU-for-IOPS trade that reduces bytes-written directly. A memory-for-IOPS trade equivalent to WAL does not exist for RocksDB under Universal Compaction.

A real memory-for-IOPS lever would require a source patch: `bytes_per_sync` is forced to 1 MB whenever the rate-limiter object is alive (`src/yb/rocksdb/db/db_impl.cc:780`), and is not exposed as a gflag. Raising it to 16 MB in code would coalesce the periodic kernel range-syncs during flush/compaction and directly cut IOPS per MB written, without changing write amplification. This is the most promising untested lever but is out of scope for gflag-only tuning.

## Practical Implications

At the current workload (~2,000 TPS, 2.3 MB/s cluster flush), the baseline 46 write IOPS on this lab is close to the mechanical floor under Universal Compaction. Meaningful IOPS reduction requires:

1. Reducing ingest (fewer tablets, lower TPS, narrower rows).
2. Reducing write amplification (compression, fewer merge rounds via `level0_file_num_compaction_trigger` paired with higher `sst_files_soft_limit` — may yield 10–20%).
3. Source patches (`bytes_per_sync`) for the biggest single win.

Memory/CPU levers on RocksDB are not a substitute for those.
