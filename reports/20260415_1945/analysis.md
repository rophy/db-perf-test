# AWS Calibration Run — Analysis

Report: `reports/20260415_1945/`
Date: 2026-04-15
Target: 200,000 TPS on AWS cluster, strategy = scale-up (6 tservers × 32 vCPU) vs k3s-virsh local baseline.

## Result

| Metric | Value |
|---|---|
| TPS | **37,761.67** |
| QPS | 37,761.67 |
| avg latency | 31.98 ms |
| p95 latency | 41.85 ms |
| errors | 0 |
| duration | 120 s (+ 30 s warmup) |
| threads | 1,200 |

**Progress:** ~19% of the 200K target. Cluster is healthy but client-starved.

## Cluster Shape

| Role | Count | Instance | Notes |
|---|---|---|---|
| db (tainted `dedicated=db:NoSchedule`) | 6 | c7i.8xlarge (32 vCPU / 64 GB, Intel Sapphire Rapids) | 1 tserver per node, RF=3, pod anti-affinity, EBS gp3 16K IOPS / 1000 MB/s, 200 GB |
| client | 1 | c7i.8xlarge | sysbench |
| system | 1 | c6i.2xlarge | 3 yb-masters + prometheus |
| k3s master | 1 | t3.small | control-plane only |

Single-AZ (ap-east-2a). All gflags mirror `values-k3s-virsh.yaml` (no RocksDB retuning).

## Infrastructure Metrics

### Per-tserver (container-level)

| Metric | Value | Utilization |
|---|---|---|
| CPU (container) | ~317% / tserver (3.17 cores) | **~10%** of 32 vCPU |
| Memory | ~1.28 GB / tserver | 2% of 64 GB |
| Network | ~6 MB/s RX + ~6 MB/s TX / tserver | trivial (< 1% of 12.5 Gbps) |
| Disk Write IOPS | ~22 / tserver | 0.1% of 16K provisioned |

### VM-level (node-exporter)

| Node | CPU total | Notes |
|---|---|---|
| 6× db | **58–66%** | ~35–40% headroom |
| system | 9% | idle |
| client (sysbench) | **2.2%** | dramatically idle |
| k3s master | 5% | idle |
| iowait / steal | 0% / 0% | no disk or noisy-neighbor pressure |
| softirq | 3.8% | moderate (network) |

Gap between **container CPU (10%)** and **VM CPU (60%)** on db nodes: ~50% of the CPU is elsewhere (flannel/CNI, softirq, kernel I/O scheduling, node-exporter, or YB's non-tserver work). Worth profiling in a follow-up.

## YugabyteDB Internal Latencies

All values are cluster-aggregate averages from Prometheus counters pulled right after the 2-min run (counters dominated by this run since tservers had only been alive ~30 min).

| Handler | Cluster avg | p99 (tserver-0, coarse) | Notes |
|---|---|---|---|
| **Write RPC** (`TabletServerService.Write`) | **5.14 ms** | — | Dominant inbound write path |
| **Read RPC** (`TabletServerService.Read`) | 0.21 ms | — | Served from memory |
| **RAFT UpdateConsensus** | 0.62 ms | 56 µs (p99 on ts0) | Follower append latency |
| **UpdateTransaction** | 2.81 ms | — | Commit-record write to txn-status tablet |
| **WAL fsync** (`log_sync_latency`) | **6.45 ms** | — | fsync on EBS gp3 |
| **WAL group commit** | 69 µs | — | In-memory batching |
| **WAL append** | 30 µs | — | Memory-only |

### Compared to k3s-virsh (reports/20260415_0138 era, dm-delay=5ms, IOPS cap=80)

| Metric | k3s-virsh | AWS | Change |
|---|---|---|---|
| TPS | 1,855 | 37,762 | **+20×** |
| sysbench p95 | 484 ms | 41.85 ms | **11× better** |
| Write RPC avg | ~72 ms | 5.14 ms | **14× better** |
| UpdateTransaction avg | ~44 ms | 2.81 ms | **15× better** |
| RAFT UpdateConsensus avg | ~2-3 ms | 0.62 ms | **4-5× better** |
| WAL fsync | ~169 ms (dm-delay) / ~4 ms (no delay) | 6.45 ms | matches no-delay baseline |

**All three of the bottlenecks identified on k3s-virsh (Write RPC, UpdateTransaction, fsync) have been neutralized.** RAFT + txn-status tablets are now sub-ms / low-ms; they are not the immediate constraint at this scale.

## Bottleneck Analysis

**Per-thread throughput:** 37,761 TPS / 1,200 threads = **31.5 TPS per thread** → matches sysbench avg latency 31.98 ms.

Each thread is serially round-tripping: client → tserver → trigger (SELECT + conditional DELETE) → WAL/RAFT → commit → response.

**Gap between internal handlers and client-observed latency:**
- Write RPC handler: 5.14 ms
- UpdateTransaction: 2.81 ms
- WAL fsync: 6.45 ms
- Client observed avg: **31.98 ms**
- Gap: ~20 ms unaccounted inside YSQL query layer, trigger execution (PL/pgSQL), query planning, and cross-pod network RTT

The `cleanup_duplicate_k` trigger materially contributes: each oltp_insert fires `AFTER INSERT` → indexed SELECT on `k` + conditional DELETE. That's 1 extra read + up to 1 extra write per logical insert.

**What is actually limiting TPS at 1,200 threads:**

| Resource | State | Implication |
|---|---|---|
| db-node CPU | 60% used, 40% idle | not the cap — can absorb ~1.5× more work |
| db-node disk IOPS | 22/tserver of 16K available | vast headroom |
| db-node memory | 2% used | vast headroom |
| db-node network | < 1% | vast headroom |
| tserver container CPU | 10% of request | not saturated |
| RAFT UpdateConsensus | 0.6 ms | not saturated |
| Txn-status UpdateTransaction | 2.8 ms | not saturated |
| WAL fsync | 6.5 ms | not saturated |
| client node CPU | **2.2%** | **massively underdriven** |

The binding constraint in this run is **concurrent thread count**, limited by YSQL `max_connections=300` / tserver × 6 = 1,800 cluster cap (we ran at 1,200 to stay comfortably under).

## Projection to 200K TPS

If per-thread latency holds flat:
- 1,200 threads → 37.8K TPS (measured)
- 3,000 threads → ~94K TPS
- 6,000 threads → ~189K TPS

That projection is optimistic: at higher concurrency, tserver CPU (currently 60%) will climb, and at some point RAFT / txn-status starts queuing. But the headroom is real — we have ~1.5× CPU, ~1000× IOPS, ~1000× network margin.

## Next Iteration

Based on this analysis, the next run should:

1. **Raise `ysql_max_connections`** gflag to 1024 (or 2048). 6 × 1024 = 6,144 cluster cap, comfortably supporting 3,000–4,000 threads. Requires tserver restart via `helm upgrade`.
2. **Drive 3,000 threads** from sysbench (2.5× current). Client node has 98% headroom.
3. **Keep workload identical** otherwise (24 × 100K rows, cleanup_duplicate_k trigger, 2-min run). Change one variable at a time.
4. **Scale CoreDNS or continue using ClusterIP shortcut**: default single CoreDNS replica saturated at 3,000 threads. Simpler: keep ClusterIP override.

Target for next run: **90–100K TPS**. If we hit that cleanly, the subsequent iteration pushes to 6,000 threads for 180–200K. If we miss, the next bottleneck will reveal itself in the Write RPC / UpdateTransaction / softirq numbers.

## Open Questions

- Why is VM CPU (60%) ~6× higher than tserver container CPU (10%)? Flannel overlay? Kernel softirq from network-heavy RPC? Worth a `perf top` or `pidstat` pass on one db node during the next run.
- At what concurrency does RAFT UpdateConsensus start climbing past 1 ms? That will be the first soft signal of txn-status or leader-disk serialization.
