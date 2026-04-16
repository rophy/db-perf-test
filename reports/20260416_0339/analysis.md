# Iter 12 — 12 tservers with confirmed trigger: scale-out stall vs 6 tservers

Report: `reports/20260416_0339/`
Date: 2026-04-16
Config: 12× c7i.8xlarge tservers (RF=3), threads=6000, warmup=90s, run=300s, `ysql_num_shards_per_tserver=2`, **cleanup_duplicate_k trigger installed on all 24 tables (dynamic SQL)**.

Purpose: establish a properly-triggered 12-tserver baseline to compare against iter 3 (12 tservers, 153K peak, trigger status previously unknown). Run follows the full reset sequence (`make clean && deploy-aws && sysbench-prepare && sysbench-trigger`).

## Result

| Metric | Value |
|---|---|
| TPS (avg over 300s) | **55,139** (depressed by 90s ramp + tail decline) |
| TPS (peak 10s window) | **81,563** (t=100s) |
| TPS (steady-state, t=100–270s) | **69K–77K** |
| p95 latency | 337.94 ms |
| avg latency | 109.73 ms |
| Errors | 0 |
| Threads | 6,000 |

## TPS Timeline

| Time | TPS | Note |
|---|---:|---|
| 10–40s | 1K–3K | Warmup (6000 threads connecting) |
| 50s | 8,785 | Post-warmup ramp |
| 60s | 23,576 | |
| 70s | 35,221 | |
| 80s | 56,308 | |
| 90s | 71,673 | |
| **100s** | **81,563** | **Peak** |
| 110s | 76,090 | |
| 120–150s | 75K–77K | Steady-state plateau |
| 160s | 69,412 | Slight dip |
| 170–240s | 73K–75K | Steady-state |
| 250s | 69,207 | |
| 260–270s | 70K–71K | |
| 280s | 50,883 | Tail decline begins |
| 290s | 32,846 | |
| 300s | 41,653 | Compaction pressure |

## Cluster utilization (from `summary.txt`)

| Metric | Value |
|---|---:|
| Container CPU (total, 12 tservers) | 1,343% (avg 112%/tserver) |
| VM CPU avg (12 db nodes) | **51–58%** |
| avg user | 29.7% |
| avg system | 9.4% |
| avg iowait | 0.0% |
| Network | RX 37.9 MB/s, TX 35.8 MB/s per cluster |
| Disk write IOPS | 142/sec cluster-wide |

db nodes have **~40% VM CPU headroom** — not saturated at steady-state. Compare to iter 2 (6 tservers) which ran at 95–98% CPU.

## Iter 3 trigger status — now conclusive

Iter 3 (`reports/20260415_2047/`, 12 tservers, 153K peak) had no trigger status documented. Comparison with this run:

| | Iter 3 | **Iter 12** |
|---|---:|---:|
| Tservers | 12 | 12 |
| Threads | 6000 | 6000 |
| Peak TPS | 153K | **81K** |
| Trigger | ??? | **Confirmed on all 24 tables** |

Iter 12's peak is 47% lower than iter 3 — exactly matching the ~42% trigger overhead measured in iter 10 (184K, no trigger) vs iter 11 (107K, full trigger). **Iter 3 ran without the trigger.**

## Anomaly: scale-out from 6→12 tservers yields no gain

| Run | Tservers | Threads | Peak TPS | Steady TPS | VM CPU |
|---|---:|---:|---:|---:|---:|
| Iter 2 | 6 | 3000 | 86K | 81–86K | **95–98%** |
| **Iter 12** | **12** | **6000** | **81K** | **69–77K** | **51–58%** |

Doubling the tserver count (6→12) did **not** scale throughput. Iter 2 was CPU-bound (95% saturated). Iter 12 has significant CPU headroom (~40%) yet cannot push higher. This is a new bottleneck that did not exist at 6-tserver scale.

### Hypotheses (none yet verified)

1. **Coordinator/fanout overhead at higher thread count:** 6000 threads × trigger's SELECT+DELETE fanout per insert means the coordinator tserver does 3× the RPC fan-out per transaction. At 12 tservers, each insert's coordinator talks to more tablet leaders on more servers, adding latency per op.
2. **Trigger SELECT hotspot:** the trigger does `SELECT id FROM table WHERE k = $1 AND id < $2 LIMIT 1`. The `k` column has a secondary index; at higher thread counts, the index tablets may become hot even as the main tablets are cool. This would manifest as CPU headroom on data tablets but saturation on index tablets.
3. **Thread contention / connection pool:** 6000 PG connections distributed across 12 tservers = 500/tserver. Iter 2's 3000 threads / 6 tservers = 500/tserver. Same per-tserver connection load, same per-tserver bottleneck — suggesting the limit is per-tserver internal (ysql_max_connections + PG process throughput), not cluster-wide.
4. **Client-side (sysbench) bottleneck:** 6000 threads on a single c7i.8xlarge client may saturate client CPU or network. VM-level shows client node at 12.6%, but that's an average — instantaneous spikes may matter.

## Next steps

1. **Re-run 6-tserver baseline with confirmed trigger** — validate iter 2's 86K peak on the current rebuilt cluster with the new dynamic-SQL trigger. Direct apples-to-apples comparison to iter 12.
2. **Check per-tserver TPS distribution** during iter 12 — if load is uneven (one tserver handling most transactions), coordinator imbalance explains the stall.
3. **Probe the per-tablet metrics** for the secondary index (`k` column) on sbtest tables — if index tablets are hot while data tablets are cool, that's the trigger SELECT bottleneck.
4. **Try higher threads on 12 tservers** (e.g., 9000) to see if more load pushes CPU higher without throughput gain (confirms non-CPU bottleneck) or does push throughput up (confirms thread-side limit).

## Verdict

12 tservers with full trigger coverage caps at **~75K steady / 81K peak**, not the 153K seen in iter 3 — confirming iter 3's "no trigger" status.

However, the cluster is **not CPU-bound** at this throughput, and doubling from 6 to 12 tservers produced no gain. The trigger workload has a different scaling profile than raw inserts, and the bottleneck is not yet identified.
