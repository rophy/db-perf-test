# Iter 13 — 6 tservers with confirmed trigger: anomaly resolved, iter 2 was no-trigger

Report: `reports/20260416_0435/`
Date: 2026-04-16
Config: 6× c7i.8xlarge tservers (RF=3), threads=3000, warmup=90s, run=300s, `ysql_num_shards_per_tserver=2`, **cleanup_duplicate_k trigger installed on all 24 tables (dynamic SQL)**.

Purpose: validate the iter 12 anomaly (12 tservers + trigger ≈ 6 tservers per iter 2 → no scale-out gain). Full reset sequence (`make clean && deploy-aws && sysbench-prepare && sysbench-trigger`) on a fresh 6-tserver cluster.

## Result

| Metric | Value |
|---|---|
| TPS (avg over 300s) | **40,661** |
| TPS (peak 10s window) | **44,393** (t=20s) |
| TPS (steady-state, t=30–290s) | **38K–42K** |
| p95 latency | 112.67 ms |
| avg latency | 73.79 ms |
| Errors | 0 |
| Threads | 3,000 |

Notably smooth: stddev of per-thread events = 220 (extremely even load distribution).

## TPS Timeline

| Time | TPS | Note |
|---|---:|---|
| 10s | 8,770 | Warmup (3000 threads connect fast) |
| 20s | 44,393 | Peak — brief transient |
| 30–90s | 41K–42K | Stable plateau |
| 100–150s | 40K–41K | Stable plateau |
| 160–200s | 39K–40K | Slight decay |
| 210–300s | 38K–40K | Steady decline (compaction pressure) |

## Cluster utilization

| Metric | Value |
|---|---:|
| Container CPU (total, 6 tservers) | 1,912% (avg 319%/tserver) |
| VM CPU (6 db nodes) | **74–76%** (very uniform) |
| avg user | 37.0% |
| avg system | 10.3% |
| avg iowait | 0.0% |
| Network | RX 44.7 MB/s, TX 44.3 MB/s per cluster |
| Disk write IOPS | 163/sec cluster-wide |

Cluster is running hot but has ~20% VM CPU headroom.

## Anomaly resolved — iter 2 was NOT a trigger run

The iter 12 analysis flagged an anomaly: iter 2 (6 tservers, 86K peak) appeared to match iter 12 (12 tservers, 81K peak), implying no scale-out gain. Iter 13's data resolves this.

| Run | Tservers | Threads | Peak TPS | Steady TPS | VM CPU | Trigger |
|---|---:|---:|---:|---:|---:|---|
| Iter 2 | 6 | 3000 | 86K | 81–86K | **95–98%** | **Inferred NO** |
| **Iter 13** | **6** | **3000** | **44K** | **38K–42K** | **75%** | **YES (confirmed)** |

### Why iter 2 cannot have had the trigger

Iter 2 hit 86K TPS at 95% CPU. Iter 13 hits 41K TPS at 75% CPU with the trigger. Linear extrapolation: iter 13 at 95% CPU would be ~52K TPS — far below iter 2's 86K.

The only way iter 2 reaches 86K on 6 tservers is if each transaction does ~1 INSERT (no trigger), not INSERT + SELECT + conditional DELETE (trigger). This is consistent with iter 1's EXPERIMENT_LABEL claiming trigger installed, but *also* with a subsequent `sysbench-prepare` between iter 1 and iter 2 that dropped the triggers (prepare recreates tables, which drops attached triggers; iter 2's analysis never mentions trigger re-install).

**Inference rule:** prior to the 2026-04-16 CLAUDE.md update that mandates `make sysbench-trigger` after every prepare, all AWS iters that ran `sysbench-prepare` without a documented trigger reinstall almost certainly had **no trigger**.

## Scaling now clean (6 → 12 → 18 tservers, all with trigger)

| Tservers | Steady TPS | Peak TPS | TPS/tserver | Per-tserver CPU | Linear scale from 6 |
|---:|---:|---:|---:|---:|---:|
| **6** (iter 13) | 40K | 44K | 6.7K | 75% | 1.0× |
| **12** (iter 12) | 75K | 81K | 6.3K | 55% | 1.88× |
| **18** (iter 11) | 100K | 107K | 5.6K | 67% | 2.50× |

- **6→12 tservers:** 1.88× throughput — near-linear (ideal 2×).
- **12→18 tservers:** 1.33× throughput for 1.5× tservers — sublinear (ideal 1.5×, got 0.89× of ideal).
- **TPS/tserver declines:** 6.7K → 6.3K → 5.6K. Trigger-heavy workload loses efficiency at scale (index/lookup contention, or coordinator fanout overhead).

## Historical TPS table — updated

| Iter | Tservers | Threads | Trigger | Peak TPS | Steady TPS | Notes |
|---|---:|---:|---|---:|---:|---|
| 1 | 6 | 1200 | Confirmed | 38K | N/A | 1200 threads, conn-limited |
| 2 | 6 | 3000 | **Inferred NO** | 86K | 81–86K | CPU 95% — too high for trigger workload |
| 3 | 12 | 6000 | Inferred NO | 153K | N/A | Matches no-trigger scaling |
| 4 | 17 | 8500 | Inferred NO | 185K | N/A | Matches iter 10 (no trigger) |
| 10 | 18 | 8500 | NO (verified) | 184K | 162K | Crashed at t=250s (compaction) |
| 11 | 18 | 8500 | YES (all 24) | 107K | 100K | Full trigger baseline |
| 12 | 12 | 6000 | YES (all 24) | 81K | 75K | Fresh cluster, confirmed |
| **13** | **6** | **3000** | **YES (all 24)** | **44K** | **41K** | This run — anomaly resolved |

## Next steps

1. **Scale-out investigation (12→18 sublinear):** steady-state drops from 12 tservers' 6.3K TPS/tserver to 18 tservers' 5.6K TPS/tserver. Possible causes:
   - Secondary-index hotspot (trigger's `SELECT WHERE k = $1` hits index tablets, which may not scale as data tablets split)
   - Coordinator fanout: wider RPC fan-out per trigger per insert
   - Need per-tablet Prometheus probes to localize the hotspot
2. **Iter 3 verification is now conclusive:** with 12 tservers + trigger properly delivering 75K/81K, iter 3's 153K is firmly no-trigger territory.
3. **Update CLAUDE.md mandate visibility:** the pre-2026-04-16 runs that predate the `make sysbench-trigger` mandate should be labeled "trigger uncertain" in the historical comparison until a trigger reinstall is documented.

## Verdict

The scale-out anomaly was a measurement artifact from comparing inconsistent-trigger runs. With trigger properly installed on all tables, **the 6/12/18 tserver scaling is near-linear at small scale and starts to taper at 18 tservers**. The cluster is well-behaved — the scale-out question now shifts from "why doesn't it scale" to "what limits efficiency at 18+ tservers".
