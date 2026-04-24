# CFS CPU Throttling Analysis: VU=3 vs VU=4

## Test Setup

- **Cluster**: 3 workers (4 vCPU each, pinned to P-cores 0-11), 1 control (2 vCPU)
- **YugabyteDB**: 3 tservers, RF=3, `limits.cpu=2` (CFS quota: 200ms per 100ms period)
- **Workload**: k6 trigger workload (INSERT + trigger-fired duplicate check), 120s run after 30s warmup
- **VU=3 report**: `reports/20260423_2331/`
- **VU=4 report**: `reports/20260424_0058/`

## Summary

| Metric | VU=3 | VU=4 | Delta |
|---|---|---|---|
| TPS (avg) | 589 | 351 | **-40%** |
| p95 latency | 6.5–7.3 ms | 27.0–28.2 ms | **+4× worse** |
| CPU/nd (container avg) | 1.97 cores | 1.85 cores | -6% |
| Errors | 0 | 0 | — |

Adding 1 VU caused TPS to drop 40% and latency to increase 4×.

## CFS Throttling

| Pod | VU=3 throttle % | VU=3 throttled s/s | VU=4 throttle % | VU=4 throttled s/s |
|---|---|---|---|---|
| yb-tserver-0 | 2.3% (max 4.1%) | 0.0009 | 0.9% (max 1.8%) | 0.0005 |
| yb-tserver-1 | 1.9% (max 3.2%) | 0.0013 | 0.0% | 0.0000 |
| yb-tserver-2 | 0.2% (max 0.8%) | 0.0001 | **90.8% (max 100%)** | **0.3187** |

At VU=3, throttling is negligible (<4% peak). At VU=4, **tserver-2 is throttled in 91% of CFS periods**,
losing 0.32 CPU-seconds per wall-second to throttling. The other two tservers are actually *less* throttled
than at VU=3 because the bottleneck on tserver-2 backs up the distributed transaction pipeline, reducing
load on the others.

## Container CPU

| Pod | VU=3 avg | VU=3 max | VU=4 avg | VU=4 max |
|---|---|---|---|---|
| yb-tserver-0 | 1.73 cores | 1.85 | 1.63 cores | 1.76 |
| yb-tserver-1 | 1.70 cores | 1.82 | 1.27 cores | 1.35 |
| yb-tserver-2 | 1.70 cores | 1.80 | **1.85 cores** | **2.00** |

At VU=3, CPU is balanced across all three tservers (~1.7 cores each). At VU=4, tserver-2 hits
the 2.00-core ceiling while the others drop — tserver-1 falls to just 1.27 cores. The imbalance
indicates tserver-2 holds hot tablet leaders and becomes the single point of contention.

## Container Memory (working set)

| Pod | VU=3 | VU=4 |
|---|---|---|
| yb-tserver-0 | 364 MB | 393 MB |
| yb-tserver-1 | 342 MB | 326 MB |
| yb-tserver-2 | 331 MB | 350 MB |

Memory is comparable between runs. Not a factor.

## Container Network RX

| Pod | VU=3 | VU=4 |
|---|---|---|
| yb-tserver-0 | 3.34 MB/s | 1.96 MB/s |
| yb-tserver-1 | 3.14 MB/s | 1.83 MB/s |
| yb-tserver-2 | 3.02 MB/s | 1.81 MB/s |

Network throughput dropped ~40% at VU=4 — proportional to the TPS drop. Network is not the
bottleneck; it dropped because fewer transactions completed.

## Container Disk Write IOPS

| Pod | VU=3 | VU=4 |
|---|---|---|
| yb-tserver-0 | 15 | 17 |
| yb-tserver-1 | 16 | 16 |
| yb-tserver-2 | 15 | 15 |

Disk IOPS nearly identical. Not a factor.

## Node-Level CPU Breakdown (per worker, 4 vCPU each)

### VU=3 (balanced)

| Mode | worker-1 | worker-2 | worker-3 |
|---|---|---|---|
| user | 1.002 | 0.988 | 0.983 |
| system | 0.498 | 0.501 | 0.489 |
| softirq | 0.187 | 0.177 | 0.179 |
| steal | 0.094 | 0.085 | 0.086 |
| iowait | 0.010 | 0.010 | 0.009 |
| **idle** | **2.003** | **2.025** | **2.041** |
| **total active** | **~2.0** | **~2.0** | **~2.0** |

### VU=4 (imbalanced)

| Mode | worker-1 | worker-2 | worker-3 (hot) |
|---|---|---|---|
| user | 0.930 | 0.656 | **1.139** |
| system | 0.498 | 0.415 | **0.535** |
| softirq | 0.182 | 0.138 | **0.198** |
| steal | 0.118 | 0.114 | **0.138** |
| iowait | 0.012 | 0.010 | 0.009 |
| **idle** | **2.093** | **2.495** | **1.855** |
| **total active** | **~1.9** | **~1.5** | **~2.1** |

Worker-3 (tserver-2) is the hottest node at VU=4 — its idle dropped to 1.86 cores while
worker-2 went *more* idle (2.5 cores). The CFS limit caps tserver-2 at 2 cores, but the
VM itself only uses ~2.1 cores total because the CFS-throttled tserver threads are sleeping
(not consuming real CPU while throttled).

### CPU Steal

| | VU=3 avg | VU=4 avg |
|---|---|---|
| worker-1 | 0.094 | 0.118 |
| worker-2 | 0.085 | 0.114 |
| worker-3 | 0.086 | 0.138 |

Steal increased slightly at VU=4 (2.1% → 2.9% of 4 vCPU). The host is mildly oversubscribed
(14 vCPU on 12 P-core threads), but steal is not the primary issue.

## Load Average

| | VU=3 | VU=4 |
|---|---|---|
| worker-1 | 2.7 | 2.3 |
| worker-2 | 2.8 | 2.2 |
| worker-3 | 2.4 | **3.9** |

Worker-3 load spiked to 3.9 at VU=4 — nearly 2× its effective CPU budget (2 cores).
This means ~2 threads are constantly runnable but waiting for the CFS scheduler. At VU=3,
load was evenly distributed ~2.6 across all workers.

## Context Switches

| | VU=3 | VU=4 |
|---|---|---|
| worker-1 | 117K/s | 63K/s |
| worker-2 | 119K/s | 59K/s |
| worker-3 | 117K/s | 70K/s |

Context switches dropped ~46% at VU=4 — because the throttled tserver-2 is blocked, reducing
scheduling activity cluster-wide. The work simply isn't getting done.

## Conclusion: Is CFS throttling a big performance hit?

**Yes, but the problem is amplified by load imbalance.**

CFS throttling itself is a binary enforcement: once a container exhausts its quota within a
100ms period, all its threads are frozen until the next period. For a database like YugabyteDB
where distributed transactions require coordination across all tservers, one throttled tserver
becomes a cluster-wide bottleneck:

1. **At VU=3**: Total cluster demand (~5.1 cores across 3 tservers) fits within the 6-core
   budget (3 × 2 cores). Load is balanced. Throttle rate <4%. No performance impact.

2. **At VU=4**: One tserver (tserver-2) becomes the hot leader. Its demand exceeds 2 cores.
   CFS throttles it 91% of periods, freezing threads mid-transaction. Other tservers idle-wait
   for tserver-2's Raft responses. Result: **-40% TPS, +4× latency** despite the cluster
   having 4 idle cores across the other two workers.

The core issue: **CFS limits are per-container, but distributed database load is per-leader**.
When tablet leaders are unevenly distributed, one container hits the ceiling while others sit
idle. A 2 vCPU VM would behave similarly for that one node, but the idle capacity on the other
nodes would also be genuinely unavailable (not wasted behind a cgroup fence).

**CFS throttling doesn't just limit CPU — it introduces latency spikes.** When threads are frozen
mid-period, in-flight RPCs stall for up to 100ms (the CFS period). This is far worse than simply
being slow: it's periodic stalls that cascade through distributed consensus. The 0.32 CPU-seconds/s
of throttle time on tserver-2 translates to threads being frozen for ~32% of wall time, directly
explaining the 4× p95 latency increase.
