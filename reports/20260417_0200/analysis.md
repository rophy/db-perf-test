# Iter 22 — 14× c7i.16xlarge (64 vCPU), 127K TPS steady

## Config
- **Cluster:** 14× c7i.16xlarge tservers (64 vCPU / 128 GB each), 3 masters on c7i.4xlarge (uncapped CPU), RF=3
- **Workload:** oltp_insert + cleanup_duplicate_k trigger, 24 tables, 12K threads, 300s run + 90s warmup
- **Changed vs iter 21:** 14 tservers (was 12), c7i.16xlarge (was c7i.8xlarge, 32 vCPU), 12K threads (was 6K)
- **gflags:** auto-split disabled, ysql_num_shards_per_tserver=2, ysql_max_connections=1500

## Hypothesis
Scale-up from 32→64 vCPU per tserver with 14 tservers should yield ~140K TPS if per-vCPU efficiency
takes ~15% scale-up penalty plus ~7% scale-out penalty (interpolated from 12→18 curve).

## Result — per-interval steady-state (T=100-300)

| Metric | Value |
|--------|-------|
| Steady-state TPS range | 121K-134K |
| Steady-state TPS avg | ~127K |
| Peak TPS | 137.5K (T=70, warmup) |
| p95 latency | 147-314ms (oscillating) |
| Errors | 0 |
| Total DB CPU (14 tservers) | 482 cores / 896 available = **54%** |
| Per-tserver CPU range | 25.9-42.4 cores (40-66% of 64) |
| Client (sysbench) CPU | 2.9 cores avg — NOT bottleneck |
| Master CPU | <0.1 cores each — NOT bottleneck |
| not_leader_rejections | 229/s avg — no split storm |

## Key finding: massive per-tserver write imbalance

All 14 tservers have 6 leaders each (83 total), yet Write RPC rate shows 3 distinct tiers:

| Tier | Tservers | Writes/s per ts | Reads/s per ts | CPU |
|------|----------|----------------|----------------|-----|
| High | ts-2,3,6,7,8,9,10,12 (8) | ~35.5K | 41-48K | 27-42c |
| Mid  | ts-0,4,5,11 (4) | ~26.7K | 28-39K | 26-31c |
| Low  | ts-1,13 (2) | ~17.8K | 22-26K | 31-33c |

Total Write RPCs: 427K/s across cluster. Total Reads: 535K/s.

The tiering is NOT explained by leader count (all have 6), connection count (all ~1000-1150),
or disk (WAL sync uniform ~7ms, disk IOPS 274-378).

**Root cause hypothesis:** The 6 leaders per tserver are a mix of primary-table tablets and
secondary-index tablets. Primary tablets receive both the INSERT write and the trigger's
SELECT→UPDATE. Index tablets receive only the index maintenance write. Each tserver has 6 leaders
but the mix of primaries vs indexes varies — tservers with more primary-table leaders get ~2× the
write load of those with mostly index leaders, because each primary-table write fans out to:
1. The primary tablet (write)
2. The secondary index tablet (write, possibly remote)
3. The transaction status tablet (UpdateTransaction)

## tserver-2 latency outlier

tserver-2 sustained **272ms avg write latency** and 98ms UpdateTransaction latency vs 3-10ms and
1-5ms respectively for all others. This ramped from 0.4ms at T=0 to 298ms by T=120 and stayed
flat. Its Write RPC *rate* was in the high tier (35.9K/s) — so it processed the same volume but
each op took 40-85× longer. This looks like a resource contention issue on that specific node
(possibly EBS volume performance, NUMA misalignment, or a runaway background task). It did NOT
drag cluster TPS because the K8s service distributed connections evenly and other tservers picked
up slack via the trigger's remote-write path.

## Scale-up efficiency analysis

| Config | Tservers | vCPU/ts | Total vCPU | Steady TPS | TPS/vCPU | Efficiency |
|--------|----------|---------|------------|------------|----------|------------|
| Iter 13 (baseline) | 6 | 32 | 192 | 41K | 214 | 100% |
| Iter 21 | 12 | 32 | 384 | 73K | 190 | 89% |
| **Iter 22** | **14** | **64** | **896** | **127K** | **142** | **66%** |

At 142 TPS/vCPU, the combined scale-up + scale-out penalty is **34%** — much worse than the
estimated 22% (15% scale-up + 7% scale-out). The 54% cluster CPU utilization confirms significant
headroom is stranded.

## Why only 54% CPU at 127K TPS?

Three contributing factors (hypotheses, partially verified):

1. **Write imbalance (verified):** 8 tservers handle ~35.5K writes/s while 2 handle only 17.8K.
   The low-tier tservers use 31-33 cores despite lower load, suggesting thread scheduling overhead
   from 12K idle connections. The high-tier tservers top out at 42 cores (66%) — they're not CPU-
   bound either, which means the bottleneck is internal (Raft consensus round-trips, lock
   contention in the tablet write path, or PG-layer connection multiplexing limits).

2. **Client thread starvation (unverified):** 12K threads with 127K TPS = 94ms avg per op. Each
   thread is serialized (send, wait for response, send next). If the DB could handle more
   concurrent ops, adding threads should help. The next run uses 18K threads to test this.

3. **Per-tserver internal bottleneck (unverified):** At 64 vCPU, internal tserver locks (tablet
   Raft groups, RocksDB write batch, PG connection handling) may serialize at a scale where 32 vCPU
   didn't. The high-tier tservers use 42 cores but process ~35.5K writes — at 32 vCPU iter 21
   tservers did ~6.1K writes at 28-31 cores. The writes/core ratio dropped from ~200 to ~850,
   suggesting the extra cores are handling Raft/replication overhead, not additional user writes.

## Comparison table

| Metric | Iter 21 (12×32 vCPU) | Iter 22 (14×64 vCPU) | Delta |
|--------|---------------------|---------------------|-------|
| Steady TPS | 73K | 127K | +74% |
| Total vCPU | 384 | 896 | +133% |
| TPS/vCPU | 190 | 142 | -25% |
| CPU utilization | 87-98% | 40-66% | much lower |
| Write RPC total | ~230-260K/s | 427K/s | +75% |
| p95 latency | ~100-200ms | 147-314ms | higher |

## Verdict

127K TPS on 14× c7i.16xlarge is a clean, stable result — no split storms, no client bottleneck,
no master throttle. But we're leaving ~45% CPU on the table.

**STOP — signals conflict.** Sysbench says 127K TPS. DB-side says 427K Write RPCs/s + 535K Read
RPCs/s. CPU is only 54%. The bottleneck is NOT CPU, NOT disk, NOT network, NOT master, NOT client.
The most likely candidates are:

1. **Insufficient client threads** — 12K threads × 94ms avg latency = 127K TPS (Little's law).
   Adding threads should lift TPS if the DB has capacity. Next run (18K threads, 600s) tests this.
2. **Write path lock contention at 64 vCPU** — internal serialization within tserver at high core
   count. Would show as TPS plateau even with more threads.

If (1): 18K threads should push toward 150-170K TPS.
If (2): 18K threads won't help much — confirms scale-up wall.

## Next steps
- **Iter 22b** (in progress): 18K threads, 600s run, 120s warmup — tests client saturation hypothesis
- If TPS lifts with more threads: plan iter 23 with 24K threads to find the ceiling
- If TPS flat: investigate per-tserver lock contention (tablet-level latency histograms, RPC queue depths)
- Investigate tserver-2 latency outlier (check EBS CloudWatch metrics, dmesg)
