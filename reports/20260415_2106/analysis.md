# AWS Iter 4 — 17× tserver scale-out, pushing toward 200K

Report: `reports/20260415_2106/`
Date: 2026-04-15
Target: **200K+ TPS** via 17× c7i.8xlarge (AWS vCPU quota blocked the 18th); threads=8500, run=300s, warmup=90s.

## Result

| Metric | Value |
|---|---|
| TPS (avg over 300s) | 89,080 |
| TPS (peak 10s window, t=180s) | **185,556** |
| TPS (steady-state, t=170-300s) | **~156,000–186,000** (avg ≈ 168K) |
| p95 latency | 240.02 ms |
| avg latency | 96.85 ms |
| max latency | 81,297 ms (ramp tail) |
| errors | 0 |
| threads | 8,500 |

**Missed 200K.** Peak 185K; steady-state averaged 168K. Ramp consumed 120s of the 300s measurement window — far more overhead than iter 3 (110s ramp at 6000 threads).

## Per-10s Window

| t (s) | TPS | p95 (ms) |
|---:|---:|---:|
| 10-110 | 838 → 4,352 | 12-14 s |
| 120 | 10,795 | 9,118 |
| 130 | 30,775 | 8.9 |
| 140 | 56,374 | 22.7 |
| 150 | 90,857 | 38.2 |
| 160 | 132,924 | 43.4 |
| 170 | 156,828 | 130 |
| 180 | **185,556** | 200 |
| 190 | 170,691 | 177 |
| 200 | 170,139 | 314 |
| 210 | 175,392 | 249 |
| 220 | 157,126 | 303 |
| 230 | 159,785 | 249 |
| 240 | 173,533 | 105 |
| 250 | 160,739 | 253 |
| 260 | 156,581 | 282 |
| 270 | 173,646 | 204 |
| 280 | 156,514 | 326 |
| 290 | 164,602 | 249 |
| 300 | 175,427 | 282 |

Ramp scaled roughly linearly with thread count: 3000 threads → 40s ramp; 6000 → 110s; 8500 → 120s. At 8500 threads the 90s warmup wasn't even enough; the first 30s of measurement was still below 5K TPS.

## Steady-State Metrics (Prometheus, t=170-300s ≈ 21:04:44-21:06:54)

| Metric | Value |
|---|---|
| db CPU avg (17 nodes) | **82.7%** avg (std dev very low: min 79%, max 84%) |
| db CPU max (hottest node) | 96.3% avg, peak **97.5%** |
| Disk W/s (cluster) | 7,084 avg, 9,373 peak |
| Net RX (cluster) | 4,593 MB/s avg, 5,869 peak |
| Write RPC avg | **24.2 ms** |
| log_sync (WAL fsync) | 6.8 ms |
| UpdateTransaction | 8.8 ms |

Load is now much more evenly distributed — the 17-node avg is 82.7% with very tight spread (min 79%, max 84% per-node averaged over the window), and the hottest node still hits 97.5% only in bursts. YB's tablet balancer has evened out compared with iter 3 (where one node averaged 88% vs cluster 75%).

## Per-Tserver Load Distribution (steady-state)

### Write RPC rate per tserver (req/s)

| tserver | rate | | tserver | rate |
|---|---:|---|---|---:|
| ts-13 | **26,226** | | ts-12 | 17,048 |
| ts-16 | **26,218** | | ts-8 | 16,680 |
| ts-0 | **25,074** | | ts-7 | 15,867 |
| ts-5 | 20,376 | | ts-11 | 15,284 |
| ts-15 | 19,457 | | ts-6 | 14,703 |
| ts-2 | 18,837 | | ts-14 | 14,528 |
| ts-9 | 18,125 | | ts-4 | 13,503 |
| ts-10 | 17,294 | | ts-3 | **10,216** |
| ts-1 | 17,056 | |  |  |

Mean 15,325 · range 10,216–26,226 · **max/min = 2.57×**, spread = 171% of mean.

### Write RPC avg latency per tserver (ms)

| tserver | ms | | tserver | ms |
|---|---:|---|---|---:|
| **ts-5** | **196.09** | | ts-1 | 8.56 |
| ts-11 | 38.82 | | ts-8 | 8.23 |
| ts-13 | 20.86 | | ts-3 | 7.91 |
| ts-0 | 16.84 | | ts-4 | 7.75 |
| ts-12 | 13.58 | | ts-15 | 6.71 |
| ts-2 | 11.76 | | ts-14 | 6.53 |
| ts-9 | 11.69 | | ts-16 | 6.37 |
| ts-6 | 9.35 | | ts-7 | 6.35 |
|  |  | | ts-10 | **5.88** |

ts-5 is an extreme outlier: 196 ms latency with only 20K req/s (moderate rate). ts-11 at 39 ms and ts-13/ts-0 at 17-21 ms are secondary hot spots.

### RAFT leader count per tserver (fairly balanced)

`is_raft_leader` sum: 5-8 per tserver, mean 6.1. Not the source of skew.

### log_sync latency per tserver (uniform)

6.79 – 7.08 ms across all 17 tservers (< 5% spread) — **disk I/O is not the cause of any hot-spot**.

### VM CPU per db node (moderate skew)

| node | CPU | node | CPU |
|---|---:|---|---:|
| ip-62 | 89.7% | ip-75 | 80.5% |
| ip-197 | 87.4% | ip-24 | 79.4% |
| ip-193 | 86.1% | ip-102 | 77.7% |
| ip-194 | 85.7% | ip-209 | 75.0% |
| ... avg 82.7% | range 75-90% (15 pp) |  |

## Load Distribution Diagnosis

Three signals disagree:
1. **RAFT leader counts are uniform** (5-8 per tserver, mean 6).
2. **Write RPC rates are massively uneven** (10K – 26K, 2.6× spread).
3. **Latency is catastrophically uneven** (5.9 – 196 ms, 33× spread).

Disk and WAL are fine everywhere (log_sync uniform at 7 ms). The skew is **inside the tserver write pipeline** — likely a few tablet leaders are the majority of writes (leader count ≠ request count), and one tablet on ts-5 is pathologically slow.

Hypothesis: sysbench hashes inserts across 24 sbtest tables × `ysql_num_shards_per_tserver=2` — with 17 tservers that's a small shard count per table, so a few tablets catch most writes. Leader placement is balanced, but the *load per leader* isn't.

## Implication for 200K

The 185K peak ceiling **is not cluster-wide saturation**. It's a handful of hot tservers (ts-5 severely, ts-0/13/16 moderately) serializing writes. If load were uniform across the 17 nodes at the *coldest* tserver's rate (10K req/s × 17 = 170K RPCs/s, but more evenly distributed), or even at the *mean* rate (15K × 17 = 260K), peak TPS could plausibly exceed 250K.

Levers to unlock this on the current hardware:
1. **Increase shard count** per table — raise `ysql_num_shards_per_tserver` from 2 to 4 or 8. With 17 tservers × 4 = 68 shards per table, hot-spot probability drops sharply.
2. **Range-partitioning on primary key** instead of hash — but would require workload changes.
3. **Investigate ts-5's pathological tablet** — 196 ms latency with moderate rate suggests a specific hot row or lock. Could be the `cleanup_duplicate_k` trigger's indexed SELECT hitting one table's hot range.

## Full Scaling Comparison

| | Iter 1 | Iter 2 | Iter 3 | Iter 4 |
|---|---:|---:|---:|---:|
| Tservers | 6 | 6 | 12 | **17** |
| Threads | 1,200 | 3,000 | 6,000 | 8,500 |
| TPS (peak) | 37.8K | 86.6K | **153.8K** | **185.6K** |
| TPS (steady avg) | 37.8K | ~83K | ~140K | ~168K |
| p95 (ms) | 41.9 | 68 | 177 | 240 |
| Write RPC avg (ms) | 5.1 | 12.5 | 17.4 | 24.2 |
| log_sync avg (ms) | 6.5 | 7.4 | 7.0 | 6.8 |
| db CPU avg | 62% | 75% | 75% | 83% |
| Hottest node peak | 98% | 99% | 99% | 98% |
| Disk W/s cluster | 130 | 2,600 | 5,054 | 7,084 |
| Net RX cluster (MB/s) | 36 | 1,600 | 3,217 | 4,593 |

### Scaling efficiency

| Hop | Tserver ratio | TPS ratio (peak) | efficiency |
|---|---:|---:|---:|
| Iter 1→2 (same hw, more threads) | 1× | 2.3× | n/a (concurrency-bound before) |
| Iter 2→3 | 2× | **1.8×** | 90% |
| Iter 3→4 | 1.42× (12→17) | **1.21×** | 85% |

Diminishing returns: going from 12 → 17 nodes (+42%) added only +21% peak throughput. Write RPC latency is climbing faster than throughput (12.5 → 17.4 → 24.2 ms). **Scaling wall is visible** — further scale-out will return progressively less.

## Why 200K Was Missed

1. **Ramp cost** — 40% of the 300s measurement was still ramping. If the 90s warmup had been 180s, the average would look much closer to steady-state. But even so, steady-state avg was ~168K, not 200K.
2. **Write RPC queuing dominates** — 24.2 ms avg is 4.7× worse than iter 1's 5.1 ms. This is tserver-internal (CPU/lock contention inside the handler), not disk (fsync is flat at 7 ms across all iters).
3. **Per-thread latency deteriorates** — at 8500 threads the avg latency is 97 ms vs iter 1's 32 ms. Each thread is waiting, not processing.
4. Per-thread TPS: 8500/168K ≈ 20/thread (vs 31 at iter 1, 28 at iter 2, 23 at iter 3) — steady decline.

## Options to Reach 200K

1. **Bigger nodes** (c7i.16xlarge, 64 vCPU). CPU headroom per tserver would roughly double — likely clears 200K sustained, possibly 250K+. Cleanest path.
2. **More tservers (22-24× c7i.8xlarge)** — but needs AWS vCPU quota increase (currently blocks 18), and scaling efficiency is already trending down (85% last hop).
3. **Reduce per-op cost** — the `cleanup_duplicate_k` trigger adds 1 extra indexed SELECT + conditional DELETE per insert. Dropping the trigger (if semantics allow) should give 1.5-2× headroom immediately. That makes 200K likely on **current** hardware.
4. **Longer warmup** — would improve the *reported* 300s-average number without changing actual capacity (peak stays 185K). Cosmetic.

## Verdict

Hit 185K peak, 168K sustained. **Wall is hardware and workload shape, not benchmark config.** The trigger-induced write amplification is a major share of the work; removing it would likely unlock 200K+ immediately even on this 17-node spec.

Next recommended iteration: **drop trigger, keep 17 tservers + 8500 threads + 300s run**. If that hits 250K+ as expected, it isolates the trigger cost and proves the raw YB capacity.
