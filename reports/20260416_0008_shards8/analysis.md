# AWS Iter 5 — 18× tserver + ysql_num_shards_per_tserver=8 (REGRESSION)

Report: `reports/20260416_0008_shards8/`
Date: 2026-04-16
Hypothesis: iter 4 per-tserver analysis suggested hot-tablet concentration; raising `ysql_num_shards_per_tserver` 2→8 would dilute hotspots and unlock 200K+.
Config: 18× c7i.8xlarge tservers (RF=3), threads=9000, warmup=120s, run=300s, shards=8.

## Result

| Metric | Value |
|---|---|
| TPS (avg over 300s) | 74,634 |
| TPS (peak 10s window, t=140s) | **122,727** |
| TPS (steady-state, t=130–250s) | **~110,000–123,000** (avg ~115K) |
| p95 latency | 297.92 ms |
| avg latency | 122.41 ms |
| max latency | 80,295 ms (ramp tail) |
| errors | 0 |
| threads | 9,000 |

**Regression vs iter 4:** peak 122K vs 185K (−34%), steady 115K vs 168K (−32%). Hypothesis falsified.

## Per-10s Window (sysbench)

| t (s) | TPS | p95 (ms) |
|---:|---:|---:|
| 40–60 | 2,577 → 3,162 | 11,732–12,609 |
| 70 | 5,544 | 10,722 |
| 80 | 21,470 | 282 |
| 90 | 43,483 | 30.8 |
| 100 | 59,588 | 49.2 |
| 110 | 74,247 | 54.8 |
| 120 | 93,039 | 58.9 |
| 130 | 109,940 | 123 |
| 140 | **122,726** | 370 |
| 150 | 118,732 | 263 |
| 160 | 113,521 | 162 |
| 170 | 117,631 | 170 |
| 180 | 112,618 | 98 |
| 190 | 110,634 | 164 |
| 200 | 106,347 | 70 |
| 210 | 110,122 | 320 |
| 220 | 120,188 | 258 |
| 230 | 109,854 | 193 |
| 240 | 117,297 | 48 |
| 250 | 113,775 | 208 |
| 260 | 79,875 | 878 |
| 270 | 41,068 | 612 |
| 280 | 94,967 | 451 |
| 290 | 119,331 | 451 |
| 300 | 118,292 | 427 |

Steady-state t=130–250s is ~110–123K; a dip at t=260–270s (41K) suggests a tablet stall or compaction burst, then recovery.

## Steady-State Metrics (Prometheus, t=130–250s ≈ 00:05:02–00:07:02 UTC)

| Metric | Value |
|---|---|
| db CPU avg (18 db nodes) | **67%** (range 48–89%, stddev ~15pp) |
| db CPU hottest | 89% (ip-10-0-1-199) |
| db CPU coldest | 48% (ip-10-0-1-114) |
| Write RPC rate (cluster sum) | ~232K req/s |
| log_sync (WAL fsync) | 6.42–6.82 ms (uniform) |
| Write RPC avg latency range | 1.67–167.69 ms |

CPU has substantial headroom (avg 67% vs iter 4's 83%); disk is uniform and fine. **The cluster is neither CPU- nor I/O-bound**.

## Per-Tserver Load Distribution (steady-state)

### Write RPC rate per tserver (req/s)

| tserver | rate | | tserver | rate |
|---|---:|---|---|---:|
| ts-14 | **20,480** | | ts-8 | 9,754 |
| ts-3 | 20,324 | | ts-6 | 7,706 |
| ts-0 | 20,193 | | ts-4 | **3,850** |
| ts-12 | 17,741 | | ts-13 | **3,853** |
| ts-16 | 16,457 | |  |  |
| ts-11 | 15,611 | |  |  |
| ts-17 | 14,740 | |  |  |
| ts-2 | 14,061 | |  |  |
| ts-1 | 14,057 | |  |  |
| ts-15 | 13,299 | |  |  |
| ts-10 | 10,099 | |  |  |
| ts-9 | 10,091 | |  |  |
| ts-5 | 10,093 | |  |  |
| ts-7 | 10,180 | |  |  |

Mean 12,908 · range 3,850–20,480 · **max/min = 5.32×**, spread 129% of mean.

**Load skew widened** vs iter 4 (2.57×). ts-4 and ts-13 have near-identical rates (3,850 and 3,853) suggesting they host only cold/non-hot tablet leaders.

### Write RPC avg latency per tserver (ms)

| tserver | ms | | tserver | ms |
|---|---:|---|---|---:|
| **ts-12** | **167.69** | | ts-13 | 1.92 |
| ts-9 | 32.59 | | ts-5 | 2.28 |
| ts-2 | 8.17 | | ts-11 | 2.05 |
| ts-14 | 5.95 | | ts-10 | 1.96 |
| ts-17 | 3.77 | | ts-6 | 1.67 |
| ts-16 | 3.12 | | (others 2.6–3.1 ms) | |

ts-12 extreme outlier at 168 ms (similar to iter 4's ts-5 at 196 ms — but ts-12 at shards=8 still chokes). Handing a tablet 8× more peers did not eliminate the outlier.

### log_sync latency per tserver (uniform)

6.42–6.82 ms across all 18 tservers (<6% spread) — **disk I/O is not the bottleneck on any node**.

### DB node CPU (steady-state)

| node | CPU | node | CPU |
|---|---:|---|---:|
| ip-199 | 89% | ip-207 | 62% |
| ip-125 | 88% | ip-156 | 57% |
| ip-120 | 82% | ip-177 | 57% |
| ip-179 | 82% | ip-113 | 53% |
| ip-64 | 81% | ip-249 | 53% |
| ip-139 | 80% | ip-161 | 52% |
| ip-233 | 74% | ip-79 | 51% |
| ip-164 | 70% | ip-114 | 48% |
| ip-132 | 67% | ip-174 | 66% |
| avg 67% | range 48–89% (41pp) |  |  |

CPU spread is **2× wider** than iter 4 (15pp → 41pp) — load skew showing up at the OS level too.

## Diagnosis: Why Shards=8 Regressed

1. **Shard overhead dominates the gain**: 8× shards/tserver = 4× more tablets vs iter 4. Each tablet = separate RocksDB instance, memtable, RAFT group, compactor. Coordination/background cost scales per-tablet without a matching throughput gain.
2. **Load skew got worse, not better**: hash distribution isn't the source of skew. ts-4 and ts-13 sitting at identical 3,850 req/s strongly implies leader placement — YB's load balancer hasn't promoted them. More shards did not redistribute load; it just created more tablets that are still unevenly pinned.
3. **Latency outlier reappeared**: ts-12 at 168 ms mimics iter 4's ts-5 (196 ms) — the outlier node shifted but the pathology persisted. Root cause is not shard count; it's likely per-pod CPU contention (noisy neighbor? co-scheduled kube-system pod?) or an internal tserver lock/queue.
4. **CPU headroom ample (avg 67%, coldest 48%)**: cluster is not compute-bound. Further shard tuning or scale-out won't help until the skew root cause is found.

## Iter 4 → Iter 5 Comparison

| | Iter 4 (17 nodes, shards=2) | **Iter 5 (18 nodes, shards=8)** |
|---|---:|---:|
| Tservers | 17 | 18 |
| Threads | 8,500 | 9,000 |
| Shards/tserver | 2 | 8 |
| Peak TPS | 185.6K | **122.7K** (−34%) |
| Steady TPS | ~168K | ~115K (−32%) |
| db CPU avg | 82.7% | 67% |
| CPU spread (range) | 15pp | **41pp** |
| Write RPC rate spread (max/min) | 2.57× | **5.32×** |
| Worst RPC latency | ts-5: 196 ms | ts-12: 168 ms |
| log_sync | 6.8 ms | 6.6 ms |

## Implications

- **Raising shards was the wrong lever.** The iter 4 hypothesis (hot-tablet concentration ⇒ dilute via shards) was naive: it didn't account for the coordination overhead of more tablets nor for leader placement being the actual source of skew.
- **Real bottleneck is leader/RPC-queue concentration, not tablet count.** Fixing this likely requires:
  - Manual leader rebalancing (`yb-admin master_leader_stepdown` loop) before the run.
  - Or investigating why specific pods consistently produce latency outliers (CPU steal? kernel-level contention? kube scheduler co-locating system pods?).
- **Next iter**: revert to shards=2 on 18 nodes (iter-4 config + 1 more node). Expected 195–210K peak. If achieved, confirms shard tuning was a distractor and the real headroom is on the same gflag set as iter 4.

## Verdict

Shards=8 is a **clear regression**. Hypothesis falsified. Reverting to shards=2 for iter 6.
