# Iter 17 — Interleave primary/index tablet replicas: NO TPS change, confirms 40K is structural

Report: `reports/20260416_0738/`
Date: 2026-04-16
Config: 6× c7i.8xlarge tservers (RF=3), threads=5000, warmup=90s, run=300s, `ysql_num_tablets=1`, trigger on all 24 tables, `rpc_workers_limit=2048`, **manually relocated tablets so each tserver holds 12 primary + 12 index replicas and leads 4 primary + 4 index**.

## Purpose

Iter 15/16 steady-state metrics showed two signs of physical imbalance on the 6-tserver cluster:

1. **SST asymmetry**: ts-0/1/4 at 2.22 GB each, ts-2/3/5 at 460 MB each (4.83×)
2. **Write handler latency spread**: 12 ms (ts-3) to 32 ms (ts-1), 2.7×
3. **Root cause** (discovered during iter 16 follow-up): the YB load balancer places all 24 primary-key tablet replicas on {ts-0, ts-1, ts-4} and all 24 secondary-index replicas on {ts-2, ts-3, ts-5}. Primaries take 10× the write traffic (INSERT + trigger DELETE) of indexes (one PK write per user-txn), so the primary trio compacts 40× more than the index trio — contending with foreground writes.

Hypothesis under test: **manually interleaving replicas + leaders evenly across all 6 tservers will fix the per-tserver latency spread and lift TPS above the ~40K ceiling.**

## Method

After running `sysbench-cleanup && sysbench-prepare && sysbench-trigger`, the load balancer re-segregated tablets on its own (confirmed systematic behavior, not a one-off).

We then manually rebalanced using `yb-admin`:

1. `set_load_balancer_enabled 0` (prevent LB from undoing our moves)
2. For each of 24 primary tablets: `REMOVE_SERVER` one follower from {ts-0/1/4}, `ADD_SERVER PRE_VOTER` on {ts-2/3/5}. Targets picked so each src loses 8 followers and each dst gains 8 replicas.
3. For each of 24 index tablets: mirror operation (REMOVE from {ts-2/3/5}, ADD on {ts-0/1/4}).
4. Sleep 30s for replica sync.
5. 24 `leader_stepdown` operations to promote the newly-placed replicas to leader, yielding 4 primary + 4 index leaders per tserver.
6. `set_load_balancer_enabled 1`.

Final placement (verified): each tserver holds 24 replicas (12 primary + 12 index) and leads 8 (4 primary + 4 index).

## Result — TPS hypothesis FALSIFIED

| Metric | Iter 16 (segregated) | Iter 17 (interleaved) | Δ |
|---|---:|---:|---:|
| TPS avg (300s) | 33,696 | **33,850** | +0.5% (noise) |
| TPS steady (last 60s) | 38.9–39.6K | **38.6–39.2K** | same |
| avg latency | 149.69 ms | 149.04 ms | unchanged |
| p95 latency | 240.02 ms | 204.11 ms | -15% |
| max latency | 19,675 ms | 25,075 ms | worse spike |
| Errors | 0 | 0 | — |

Interleaving did not move steady-state TPS. The ~40K ceiling held.

## Physical balance DID improve

| Metric | Iter 15 (baseline) | Iter 17 (interleaved) | Change |
|---|---:|---:|---:|
| VM CPU range | 62–76% | **62–68%** | 14pp → 6pp spread |
| Write handler latency range | 12–32 ms (2.7×) | **20.7–39.0 ms (1.88×)** | narrowed |
| SST size range | 0.46–2.22 GB (4.83×) | ~0.95–1.60 GB (1.68×) | narrowed |
| Container CPU total | 1,444% | 1,550% | +7% (less compaction stalling) |

So the relocation *worked* as a physical rebalance — it just didn't unlock more throughput.

## Interpretation

The per-tserver Write latency didn't collapse to a single value because **write volume per leader remained uneven**:

- Each tserver now leads 4 primary tablets. Primaries absorb the full INSERT + trigger DELETE load (≈2 writes per user-txn × 33.8K TPS / 24 primary tablets = ~2.8K writes/s per primary leader).
- Each tserver also leads 4 index tablets. Indexes take only the secondary-index write from each INSERT (≈1.4K writes/s per index leader).
- Ratio ~2:1. Handler latency tracks offered load roughly proportionally, so 20 ms (index-dominated intervals) vs 39 ms (primary-dominated) is the remaining asymmetry.

But the more important observation: **narrowing the spread from 2.7× → 1.88× produced 0% TPS change**. If uneven handler latency were the gating constraint, we'd have seen *some* movement. We didn't. Therefore the gating constraint is something else — the per-transaction critical path itself.

## Updated bottleneck model

The 40K TPS ceiling at 6 tservers is structural:

- **Little's Law fit**: `TPS = threads / avg_latency`. At 5000 threads / 149 ms = 33.5K. Iter 15 observed 33,738; iter 16 observed 33,696; iter 17 observed 33,850. All three runs match the model within noise.
- **Per-user-txn RPC chain**: 1 FinishTransaction + ~7 UpdateTransaction + ~4 Write + ~4.5 Read = ~16 RPCs per txn, each 9–32 ms. Serial because the trigger's `SELECT` depends on `INSERT` committing, then `DELETE` depends on the SELECT.
- **Two-tablet writes → 2PC on every INSERT**: every sysbench transaction touches the primary-key tablet + secondary-index tablet, which under hash partitioning almost always live on different tservers. This forces the distributed-transaction coordinator protocol with all its RPC hops.

No tuning knob tested so far has shifted the critical path length. The ceiling is a property of the schema + workload combination.

## Knobs tried and ruled out (cumulative)

| Knob | Iter | Result |
|---|---|---|
| `ysql_num_tablets: 1 → 12` | 14 | -24% regression (more distributed-tx fanout) |
| sysbench `threads: 3000 → 5000` | 15 | -17% regression (coord contention) |
| `rpc_workers_limit: 1024 → 2048` | 16 | 0% change |
| **Interleave primary/index tablets + leaders** | **17** | **0% change (physical balance improved but not gating)** |

## Historical TPS table

| Iter | Tservers | Threads | Placement | `rpc_workers_limit` | Peak TPS | Steady TPS | Notes |
|---|---:|---:|---|---:|---:|---:|---|
| 11 | 18 | 8500 | default (LB) | 1024 | 107K | 100K | Near-linear scale-out |
| 12 | 12 | 6000 | default (LB) | 1024 | 81K | 75K | 1.88× over 6 tservers |
| 13 | 6 | 3000 | default (LB) | 1024 | 44K | 41K | Baseline |
| 14 | 6 | 3000 | default, 12 tablets/table | 1024 | — | 31K | regressed |
| 15 | 6 | 5000 | default (LB) | 1024 | — | 34K / 40K steady | more threads regressed avg |
| 16 | 6 | 5000 | default (LB) | 2048 | — | 34K / 40K steady | no change |
| **17** | **6** | **5000** | **interleaved (manual)** | **2048** | **—** | **34K / 40K steady** | **same** |

## Incidental finding — YB load balancer placement bug

The YB master's load balancer consistently places all primary-key tablet replicas of sbtest on one trio of tservers and all secondary-index replicas on the other trio — despite uniform zone labels (`cloud1/datacenter1/rack1`) and ending with balanced replica counts (24 per tserver). `get_is_load_balancer_idle` reports idle because the LB uses replica count as its balance metric, not per-table-type distribution.

For tables where primary and index receive very asymmetric write traffic (as here, since the trigger amplifies primary writes), this results in compaction hotspotting. The workaround is either:

- manual `yb-admin change_config` relocation (this iter), or
- distinct zone labels per tserver + `modify_placement_info` to force cross-zone replica spread, or
- patch the LB (upstream).

The fix doesn't move TPS on this specific workload (because the cap is structural), but it would matter for workloads where the critical path *is* physical-capacity-bound.

## Recommended next steps

1. **Stop tuning physical balance on this workload.** Four consecutive iterations ruled out the plausible imbalance levers.
2. **Scale-out remains the only throughput lever.** 6→12→18 tservers shown near-linear.
3. **Schema change** would move the ceiling:
   - Drop the secondary index → 1-tablet writes, no distributed-txn → estimated 1.5–2× TPS.
   - Colocate sbtest tables → single-tablet raft append → estimated 3–4× TPS.
4. **Report the LB placement bug upstream** — useful for the community even though it doesn't gate this benchmark.
5. **Accept 41K as the 6-tserver ceiling** for trigger-enabled sysbench oltp_insert.

## Verdict

The 40K TPS ceiling is NOT caused by uneven tablet-replica placement. Iter 17 directly falsified that hypothesis with an A/B: the physical rebalance worked (CPU evened out 14pp → 6pp, handler-latency spread narrowed 2.7× → 1.88×) but TPS stayed at 33.8K. Combined with the earlier ruling-out of CPU / WAL / RocksDB / rpc pool / threads / tablet count, the distributed-transaction critical path is confirmed as the structural cap.
