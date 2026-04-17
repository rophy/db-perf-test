# Iter 22b — 18K threads, 600s run: more threads ≠ more TPS, confirms internal bottleneck

## Config
- **Cluster:** same as iter 22 — 14× c7i.16xlarge (64 vCPU / 128 GB), 3 masters on c7i.4xlarge, RF=3
- **Workload:** oltp_insert + cleanup_duplicate_k trigger, 24 tables, **18K threads** (was 12K), **600s run** (was 300s), 120s warmup
- **Changed vs iter 22:** +50% threads (12K→18K), +100% run duration (300→600s), ysql_max_connections 1500→2000

## Hypothesis
Two hypotheses under test:
1. **Client saturation:** iter 22's 127K TPS was limited by 12K threads (Little's law: 12K × 94ms = 127K). 18K threads should lift to ~150K+ if DB has headroom.
2. **LB rebalancing:** longer run (600s) gives the load balancer time to settle after rolling restart.

## Result — per-interval steady-state

| Metric | Iter 22 (12K thds, 300s) | Iter 22b (18K thds, 600s) |
|--------|--------------------------|---------------------------|
| Early run TPS (T=130-200) | 121-134K, avg 127K | 116-132K, avg 124K |
| Late run TPS (T=400-600) | n/a (run ended T=300) | 114-125K, avg 119K |
| Full run-phase avg | ~127K | ~120K |
| p95 latency | 147-314ms | 75-326ms |
| Cluster CPU% | 74-78% | 75-80% |
| Client CPU | 2.9 cores | 3.0 cores |
| Errors | 0 | 0 |

**18K threads produced 5-7% LESS throughput than 12K threads.** Both hypotheses disproved.

## Key findings

### 1. More threads hurt: thread contention on 16 vCPU client
- 18K pthreads on c7i.4xlarge (16 vCPU): **256K context switches/s**
- Each thread is synchronous (send → block → recv → repeat); 18K threads / 16 cores = 1125 threads per core
- Client CPU was only 3 cores — threads spend most time in kernel scheduler, not user-space
- Network was 100 MB/s TX / 96 MB/s RX (7% of c7i.4xlarge bandwidth) — not saturated
- Sysbench memory: 9.1 GB / 24 GB limit — not saturated

### 2. TPS declines over 600s due to table growth
- T=130 (run start): ~132K TPS
- T=360 (mid-run): ~121K TPS
- T=600 (run end): ~115K TPS
- 13% decline over 470s of the run phase
- The trigger's `SELECT id FROM sbtest WHERE k=$1` scans more rows as the table grows (oltp_insert appends)
- This is expected behavior for this workload — iter 22's 300s run avoided the worst of it

### 3. Rolling restart caused leader rebalancing during warmup
- Leader count spiked to 131 (from expected 83) after restart — tservers that came up first grabbed extra leaders
- LB corrected 131→83 leaders over ~3 minutes (T=80 to T=270)
- `not_leader_rejections`: 88-183/s during rebalance (moderate, not a storm)
- By T=270, leaders were balanced at 6 per tserver — rebalance complete
- TPS didn't improve after rebalance, confirming the bottleneck is not placement

### 4. DB-side CPU still only 75-80%
- Same as iter 22: tservers using 40-50 cores of 64 available
- The extra threads didn't increase DB CPU utilization
- Confirms an internal per-tserver serialization bottleneck (not CPU, not client)

## Scale-up efficiency

| Config | Threads | Steady TPS | TPS/vCPU | vs Baseline |
|--------|---------|------------|----------|-------------|
| Iter 13 (6×32) | 6000 | 41K | 214 | 100% |
| Iter 21 (12×32) | 6000 | 73K | 190 | 89% |
| Iter 22 (14×64) | 12000 | 127K | 142 | 66% |
| **Iter 22b (14×64)** | **18000** | **120K** | **134** | **63%** |

## Verdict

The 14× c7i.16xlarge cluster ceiling is **~127K TPS** (iter 22 with 12K threads). Adding threads
or time does not help — it slightly hurts. The bottleneck is **internal to each tserver at 64 vCPU**:

- Not CPU (54-80% utilized)
- Not disk (WAL sync 7ms, disk IOPS low)
- Not network (7% of bandwidth)
- Not client (3/16 cores, 7% network)
- Not master (0.02 cores)
- Not leader placement (balanced 6 per tserver)

Most likely: **Raft consensus round-trip latency and per-tablet write path serialization.** Each
write goes through Raft consensus (leader → 2 followers), which serializes per-tablet. With
`ysql_num_shards_per_tserver=2` and 14 tservers, each table has 28 tablets. The parallelism ceiling
is bounded by tablets × concurrent Raft groups, not by CPU. More vCPU per tserver doesn't increase
Raft parallelism — it just adds cores that sit idle waiting for consensus round-trips.

## Implications for 200K TPS

Scale-up path is exhausted at ~127K TPS on 14× c7i.16xlarge. To reach 200K:

1. **Scale-out on c7i.8xlarge** (known curve): ~36-42 tservers at 32 vCPU each. Per-tserver
   efficiency at 32 vCPU is much better (190 TPS/vCPU vs 142). Needs vCPU quota increase to 2000.
2. **Increase tablets per tserver** to add Raft parallelism: `ysql_num_shards_per_tserver=4` on
   14× c7i.16xlarge might unlock the idle CPU. But iter 14 showed tablet count regression on
   smaller clusters — needs validation.
3. **Hybrid:** 24× c7i.8xlarge (768 vCPU, under 1000 quota) — extrapolates to ~146K from the
   known curve. Still short of 200K.

**Recommendation:** Wait for vCPU quota increase to 2000, then run 24× c7i.8xlarge (scale-out).
If that confirms ~146K, the path to 200K is 36× c7i.8xlarge (1152 vCPU).
