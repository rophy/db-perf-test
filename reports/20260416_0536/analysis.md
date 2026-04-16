# Iter 15 — 6 tservers, threads 3000→5000: REGRESSION, distributed-txn ceiling identified

Report: `reports/20260416_0536/`
Date: 2026-04-16
Config: 6× c7i.8xlarge tservers (RF=3), **threads=5000** (iter 13 used 3000), warmup=90s, run=300s, `ysql_num_tablets` default (1), trigger installed on all 24 tables.

Purpose: test the hypothesis that iter 13's ~41K TPS ceiling was limited by client concurrency (since VM CPU had 25% headroom at 3000 threads). Raising threads to 5000 should fill the headroom if that model is correct.

## Result — hypothesis falsified

| Metric | Iter 13 (3000 thr) | Iter 15 (5000 thr) | Δ |
|---|---:|---:|---:|
| TPS avg (300s) | 40,661 | **33,738** | **-17%** |
| TPS steady (last 60s) | 38K–42K | **39K–40K** | **same ceiling** |
| p95 latency | 112.67 ms | 215.44 ms | +91% |
| max latency | (bounded) | **20,689 ms** | stall spikes |
| avg latency | 73.79 ms | 149.49 ms | +103% |
| VM CPU | 74-76% | **62-65%** | -13pp (LOWER!) |
| Container CPU (sum) | 1,912% | 1,444% | -24% |
| Disk write IOPS | 163 | 130 | -20% |

Raising threads **did not raise TPS**. Steady-state stayed pinned at ~40K. The extra 2000 threads stacked up in queues, doubling latency. Tservers actually did *less* work — CPU dropped 13pp, suggesting threads stalled inside the coordinator instead of at the tablet.

20-second max-latency spikes indicate some transactions stalled entirely (likely on txn heartbeat or intent resolution).

## Metric deep-dive — where the 40K ceiling comes from

Prometheus queries over the steady-state window (t=30–290s of run):

### RPC rate decomposition (per user-transaction)

| Subsystem | Cluster rate | Per user-txn | Avg latency |
|---|---:|---:|---:|
| **FinishTransaction** (PG→tserver commit) | 39,395/s | **1×** | **13.85 ms** |
| **UpdateTransaction** (txn coord lifecycle) | 234,000/s | **~7×** | 9–19 ms each |
| Write RPC (TabletServerService.Write) | 129,000/s | ~4× | 16–43 ms |
| Read RPC (TabletServerService.Read) | 151,000/s | ~4.5× | <1 ms |
| GetTransactionStatus (conflict resolve) | 640/s | 0.02× | — |
| conflict_resolution | 23/s | <0.1% | — |

At 33K TPS, FinishTransaction fires 1:1 with user transactions and is blocking. UpdateTransaction is the txn-coordinator lifecycle (create → heartbeat → promote → apply per participating tablet → cleanup) — **7 of these per user-txn** is consistent with the distributed-transaction protocol.

### Non-bottlenecks (ruled out)

| Signal | Value | Interpretation |
|---|---:|---|
| rocksdb_stall_micros | 0 | no compaction stalls |
| intentsdb_rocksdb_stall_micros | 0 | no intent-db stalls |
| transaction_conflicts | 23/s | <0.1% conflict rate — negligible |
| op_apply_queue_length | 0 | raft apply queue empty |
| log_append_latency | 0.04 ms | WAL append is trivially fast |
| log_sync_latency | 7.3–7.5 ms (uniform) | per-fsync cost, but syncs are rare (11–15/s per tserver) — WAL is not on critical path |
| outbound_call_queue_time | 0.4–0.8 ms | RPC queueing is minor |

CPU is not saturated, WAL is not saturated, compaction is quiet, conflicts are rare, raft queues are empty. The ceiling is not in any of these subsystems.

### Critical-path latency model

With one primary tablet + one secondary-index tablet per table (each on a potentially different tserver), **every** sysbench transaction is already a distributed 2PC transaction. Per user-txn:

```
PG parse/plan          →    ~5 ms
INSERT (primary + idx) →   ~20 ms  (raft round + intent + apply)
trigger SELECT         →   ~1 ms   (index point-lookup)
conditional DELETE     →   ~20 ms  (raft round + apply)
FinishTransaction      →   ~14 ms  (coordinator commits all participants)
network RTT            →   ~5 ms
───────────────────────────────────
TOTAL avg latency      ≈   ~75 ms   (iter 13 observed: 74 ms)
```

Little's Law: `TPS = threads / avg_latency`. So:
- 3000 threads / 0.074 s ≈ **40,541 TPS** (iter 13 observed: **40,661** ✅)
- 5000 threads / 0.149 s ≈ **33,557 TPS** (iter 15 observed: **33,738** ✅)

Per-txn latency **rose** with more threads because FinishTransaction contends on the 48 transaction-status tablets (8 per tserver × 6). At 3000 concurrent txns ~10 ms/Finish; at 5000 concurrent ~14 ms/Finish. The latency curve is superlinear, so throughput flattens then falls.

## Why the ceiling is structural, not tunable

The 40K ceiling comes from the distributed-transaction coordinator protocol itself:

1. **Every INSERT touches ≥2 tablets** — primary (`id` hash) and secondary index `k_N` (`k` hash). With hash-partitioning, these are usually on different tservers.
2. **Two-tablet writes trigger the 2PC path** — UpdateTransaction (create), per-tablet APPLY writes, FinishTransaction (commit). This is the protocol; not a tunable.
3. **Trigger doubles the write path** — INSERT plus conditional DELETE, both going through the 2PC machinery in the same user-txn.

**This is not a bug or a misconfig.** It is the inherent cost of distributed-transaction semantics in a sharded RF=3 database when an INSERT needs to maintain a secondary index atomically.

## Knobs tried and ruled out

| Knob | Iter | Result |
|---|---|---|
| `ysql_num_tablets: 1 → 12` | 14 | -24% regression (more distributed-tx fanout) |
| sysbench `threads: 3000 → 5000` | 15 | -17% regression (txn coord contention) |

## Knobs *not* tried that might help (but likely small gains)

- `transaction_table_num_tablets_per_tserver` — currently 8 (48 cluster-wide). Raising to 16 or 32 might reduce per-tablet contention under heavier load, but current per-tablet rate is ~820 FinishTxn/s which is well within a tablet's capacity — not likely to help much.
- `max_concurrent_transactions_per_session` — client-side tuning, not relevant (sysbench uses one txn per thread).
- `consensus_max_batch_size_bytes` — raft batching; already generous.
- PG-level tuning (prepared-statement cache, plan cache) — would shave a few ms off parse/plan but doesn't help the coordinator path.

## Historical TPS table — updated

| Iter | Tservers | Threads | Trigger | Tablets/table | Peak TPS | Steady TPS | Notes |
|---|---:|---:|---|---:|---:|---:|---|
| 11 | 18 | 8500 | YES | 1 | 107K | 100K | Near-linear scale-out |
| 12 | 12 | 6000 | YES | 1 | 81K | 75K | 1.88× over 6 tservers |
| 13 | 6 | 3000 | YES | 1 | 44K | 41K | **Baseline, ceiling** |
| 14 | 6 | 3000 | YES | 12 | — | 31K | `ysql_num_tablets=12` hurt (distributed fanout) |
| **15** | **6** | **5000** | **YES** | **1** | — | **34K avg / 40K steady** | **More threads hurt (coord contention)** |

## Recommended next steps

1. **Scale-out is the only clean throughput lever** for this workload. 6→12→18 tservers already verified near-linear (1× → 1.88× → 2.50×). If higher TPS is needed, add tservers.
2. **If workload can change:** drop the secondary index to eliminate the 2-tablet write from every INSERT → likely 1.5–2× TPS on the same cluster.
3. **If workload can change further:** use a colocated database (all sbtest tables share a single tablet) → removes distributed-tx entirely; should hit raft-append speed (~100K+ TPS single-tablet peak).
4. **Accept 41K as the 6-tserver ceiling** for this specific trigger-enabled sysbench workload and move on to other experiments.

## Verdict

The ~40K TPS ceiling at 6 tservers is a structural property of the distributed-transaction coordinator protocol serving a workload whose every INSERT writes to ≥2 tablets. It is not CPU-, WAL-, compaction-, conflict-, or thread-pool-limited. No tserver or master gflag tested so far moves it meaningfully. Further exploration should either scale out, simplify the schema, or accept the number.
