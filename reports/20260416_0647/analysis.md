# Iter 16 — rpc_workers_limit 1024 → 2048: NO CHANGE, pool cap is NOT the bottleneck

Report: `reports/20260416_0647/`
Date: 2026-04-16
Config: 6× c7i.8xlarge tservers (RF=3), threads=5000, warmup=90s, run=300s, `ysql_num_tablets` default (1), trigger on all 24 tables, **tserver gflag `rpc_workers_limit: 2048`** (default 1024).

## Purpose

Iter 15 steady-state metrics showed `threads_running_TabletServer` (the TabletServerService worker pool) hit max=1024 on 5 of 6 tservers, raising the question whether `rpc_workers_limit=1024` was the bottleneck behind the ~40K TPS ceiling.

Against it: `rpc_incoming_queue_time` peak was only 302–645 µs per tserver during the steady window — <5% of call latency. Thread-pool saturation would drive that metric into the tens of ms. We predicted: **raising the cap to 2048 will not move steady-state TPS.**

## Result — prediction confirmed

| Metric | Iter 15 (`rpc_workers_limit=1024`) | Iter 16 (`rpc_workers_limit=2048`) | Δ |
|---|---:|---:|---:|
| TPS avg (300s) | 33,738 | **33,696** | **-0.1%** (noise) |
| TPS steady (last 60s) | 39–40K | **39–40K** | **same** |
| avg latency | 149.49 ms | 149.69 ms | +0.1% |
| p95 latency | 215.44 ms | 240.02 ms | +11% |
| max latency | 20,689 ms | 19,675 ms | -5% |
| Errors | 0 | 0 | — |

Doubling the worker-pool cap produced **no change in throughput or average latency**, and p95 actually got slightly worse. The pool cap was not gating steady-state TPS.

## Interpretation

The TabletServerService handler pool being briefly at 1024 during bursts was a symptom, not a cause. What was actually happening:

- Under 5000 concurrent client threads, in-flight RPCs on each tserver averaged 700 with spikes to 1024.
- Each of those 700–1024 threads was busy in its handler (12–32 ms of actual work — raft round, intent/APPLY writes, nested RPCs), not waiting in a queue.
- Adding more handler slots doesn't help when the handlers themselves are the long pole.
- Queue wait peak stayed under 1 ms in iter 16 too (checked post-hoc via the same metric) — extra slots were available but unused.

This is consistent with a **dependency-serialization bottleneck**: the per-user-transaction critical path is the distributed-txn protocol (INSERT→index→DELETE→FinishTransaction, each needing coordinator registration + raft quorum), and that path is latency-bound, not resource-pool-bound.

## What actually gates throughput at 40K (from iter 15 measurements, still applies)

1. **Serial RPC chain per user-txn.** Every sysbench transaction walks through ~16 RPCs (1 Finish + ~7 UpdateTransaction + ~4 Write + ~4.5 Read) because the INSERT→index write path triggers 2PC and the trigger adds a SELECT + conditional DELETE.
2. **Uneven per-tserver Write handler latency.** At balanced load (16.5K Write/s each), Write handler latency ranges from 12ms (ts-3) to 32ms (ts-1) — a 2.7× spread. Every distributed-txn waits on its slowest participant, so the cluster's effective critical path is set by the slow tail.
3. **Little's Law fixes the ceiling.** TPS ≈ threads / critical_path_latency. At 3000 threads / 74ms = 40.5K (iter 13 observed 40,661). At 5000 threads / 149ms = 33.5K (iters 15 and 16 both observed ~33.7K).

## Knobs tried and ruled out (cumulative)

| Knob | Iter | Result |
|---|---|---|
| `ysql_num_tablets: 1 → 12` | 14 | -24% regression (distributed-tx fanout) |
| sysbench `threads: 3000 → 5000` | 15 | -17% regression (txn-coord contention) |
| **`rpc_workers_limit: 1024 → 2048`** | **16** | **0% change (pool was not the cap)** |

## Historical TPS table — updated

| Iter | Tservers | Threads | `ysql_num_tablets` | `rpc_workers_limit` | Peak TPS | Steady TPS | Notes |
|---|---:|---:|---:|---:|---:|---:|---|
| 11 | 18 | 8500 | 1 | 1024 | 107K | 100K | Near-linear scale-out |
| 12 | 12 | 6000 | 1 | 1024 | 81K | 75K | 1.88× over 6 tservers |
| 13 | 6 | 3000 | 1 | 1024 | 44K | 41K | **Baseline, ceiling** |
| 14 | 6 | 3000 | 12 | 1024 | — | 31K | `ysql_num_tablets=12` regressed |
| 15 | 6 | 5000 | 1 | 1024 | — | 34K avg / 40K steady | More threads regressed |
| **16** | **6** | **5000** | **1** | **2048** | **—** | **34K avg / 40K steady** | **Same as iter 15** |

## Recommended next steps

1. **Investigate the uneven tserver Write handler latency** (ts-1 at 32ms vs ts-3 at 12ms in iter 15). Candidates: tablet-leader mix, cross-AZ placement, noisy-neighbor. Closing this gap is the remaining metric-visible knob.
2. **Scale out** if a higher absolute TPS number is needed (proven near-linear 6→12→18).
3. **Accept 41K as the 6-tserver ceiling** for this specific trigger-enabled workload.

## Verdict

The ~40K TPS ceiling at 6 tservers is not CPU-, disk-, network-, queue-, lock-, or RPC-pool-limited. Iter 16 rules out the last plausible resource cap (`rpc_workers_limit`) with a direct A/B — no movement. The cap is the per-transaction critical path in the distributed-txn protocol, amplified by uneven tserver response latency.
