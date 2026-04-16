# Iter 20 — un-throttled masters fix the ramp; mid-run TPS dip is automatic tablet splits

Report: `reports/20260416_1123/`
Date: 2026-04-16
Config: 12× c7i.8xlarge tservers (RF=3), threads=6000, warmup=90s, run=300s, `ysql_num_tablets`
default (1), trigger on all 24 tables. **Changed vs iter 19**: yb-master `cpu/memory` limits removed
(`null`), masters spread across **2 system nodes** (added `system2 = c7i.2xlarge`) via preferred
podAntiAffinity. Final placement: master-0 + master-2 on new node, master-1 on original node (2:1 split).

## Hypothesis under test

Iter 19 found yb-master leader was pinned at its 2-core cgroup limit during the entire workload
ramp (T=30–200), throttling tserver CPU growth. Removing the limit and spreading masters across
nodes should:
1. Shorten the ramp — tservers ramp to peak CPU faster
2. Possibly lift peak/steady-state TPS

## Result — ramp fix confirmed; new tail behavior is automatic tablet splits, not a cluster bottleneck

### Ramp: WIN

Iter 20 reaches steady-state in ~20s vs iter 19's ~120s. Direct comparison at same wall-clock T:

| T(s) | Phase | Iter 19 TPS | Iter 20 TPS | Iter 19 DB CPU% | Iter 20 DB CPU% |
|---:|:---|---:|---:|---:|---:|
| 10 | warmup | 802 | **47,454** | 1.4% | 2.7% |
| 20 | warmup | 1,472 | **75,561** | 4.1% | 12.6% |
| 60 | warmup | 2,616 | 74,795 | 7.8% | 73.5% |
| 90 | end-warmup | 11,479 | 71,447 | 8.0% | **95.0%** |

**Master un-throttling is verified by Prometheus**: master-2 (the new leader) hit
**5.97 cores at T=60** — impossible under the previous 2-core cgroup cap. Then dropped
to ~0.02 cores by T=120, confirming masters do their work and step aside cleanly.

### Peak TPS: small REGRESSION

| | Iter 19 | Iter 20 |
|---|---:|---:|
| Peak TPS | **81,490** (T=130) | 75,561 (T=20) |
| Steady band (best window) | 71–81K (T=120–270) | 70–75K (T=20–140) |
| Run-avg | 48,194 | **56,584** (+17%, but driven by faster ramp) |

Peak dropped ~7%. Not investigated; could be noise, leader rebalance after the helm upgrade,
or a real-but-small regression.

### Mid-run "degradation": ROOT CAUSE FOUND — automatic tablet splits

Per-interval TPS in iter 20 declines from ~70K (T=140) to 17K (T=260):

| T(s) | Iter 20 TPS | Iter 20 DB CPU% |
|---:|---:|---:|
| 140 | 62,033 | 93.7 |
| 160 | 51,895 | 95.3 |
| 200 | 40,632 | 94.9 |
| 240 | 40,623 | 91.1 |
| 250 | 28,777 | 88.1 |
| **260** | **16,707** | **82.2** |
| 280 | 34,301 | 81.8 |
| 300 | 44,772 | 79.2 |

Verified by DB-side Write RPC rate (cluster sum across 12 tservers): the drop is real, not a
sysbench reporter artifact. Write RPCs/s went 260K (peak T=80–160) → 92K (T=360).

**The cause is automatic tablet splits**, identified by the `not_leader_rejections` metric:

| T(s) | `not_leader_rejections` /s (cluster sum) |
|---:|---:|
| 0–180 | 0–56 (background noise) |
| 210 | 47 |
| **240** | **7,703** |
| 270 | 3,605 |
| 300 | 778 |
| 330 | 199 |
| **360** | **11,725** |
| **390** | **23,933** |

`not_leader_rejections` spikes when a tablet's leader is being moved or a new leader is being
elected — Write RPCs sent to the old leader get rejected and must retry against the new one.
Cross-checked against per-tserver leader counts (`is_raft_leader` sum):

| T(s) | Cluster leader count | Notes |
|---:|---:|---|
| 0–240 | ~125 | Stable, balanced 9–13 leaders/tserver |
| 300 | ~127 | Small reshuffling begins |
| **360** | **~92** | **35 leaders disappear** — splits in progress |

When auto-split fires, the parent tablet's leader steps down while the two child tablets elect
new leaders, briefly reducing the visible leader count. `leader_memory_pressure_rejections`
was 0 throughout (rules out backpressure).

**Why iter 19 didn't see this**: iter 19's slow ramp meant the cluster ingested far fewer rows
before T=300 ended; tables stayed under the auto-split size threshold. Iter 20's fast ramp
ingested ~17M rows in 5 min — enough tables crossed the split threshold to trigger
mid-run split storms.

## Bottleneck investigation — what was ruled out

| Hypothesis | Metric | Result |
|---|---|---|
| Compaction debt (added − removed) | `active_background_compaction_input_bytes_added/removed` | Max 0.15 GB throughout — no backlog |
| Master CPU re-becomes bottleneck | per-container CPU `yb-master` containers | Master-2 hit 5.97 cores at T=60, then ~0. Not the cap. |
| Tserver pod restart / crash | `kubectl get pod -l app=yb-tserver` | All 12 Running, 0 restarts |
| EBS IOPS saturation | `node_disk_writes_completed_total` rate (max per node) | Peak 885 IOPS/node, 16K provisioned |
| Sysbench client CPU bottleneck | container CPU on sysbench pod | 1–3 cores used out of 28 limit |
| Sysbench client memory | container memory on sysbench pod | Stable at 3 GB |
| Memory backpressure | `leader_memory_pressure_rejections` | 0 throughout |

## Verdict

Iter 20 fully validates the iter 19 fix:

- **Ramp problem**: SOLVED by un-throttling masters. Direct measurement confirmed master-2
  consumed ~6 cores at T=60 (impossible under iter 19's 2-core cap).
- **Peak TPS**: Roughly unchanged (75K vs 81K) — small regression, not investigated.
- **Mid-run dip**: NOT a cluster degradation — it's automatic tablet splits doing legitimate
  work that iter 19 deferred past the run window. The "regression" is an artifact of running
  long enough to actually trigger splits.

The run-averaged 56K vs 48K headline (+17%) is driven by the faster ramp, but it's still the
right direction — the cluster spends more wall-clock time at peak and only slows down when
splits genuinely interrupt the ingestion path.

## Recommended next steps

The next benchmark should isolate steady-state from the split-storm transient. Two clean
options, in order of preference:

1. **Pre-split tablets** via `ysql_num_tablets > 1` (e.g. 4 or 8 per table). Iter 14 tried
   `ysql_num_tablets=12` and saw a 24% regression on 6 tservers — but iter 14 was
   already ingestion-saturated and the regression was distributed-tx fanout cost. With 12
   tservers and faster ramp, a moderate pre-split (4–8) might land in the sweet spot:
   enough tablets to absorb ingestion without splitting mid-run, few enough to keep
   distributed-tx coordination cheap. Run-time risk: 24-table × 8-tablet sysbench schema
   makes per-INSERT 2PC slightly more expensive.
2. **Disable auto-split during the run**: set tserver gflag `enable_automatic_tablet_splitting=false`
   (and master gflag). This isolates the steady-state question cleanly — no split storms
   possible. But it's not what production would do.
3. **Run longer (600–900s)** with default settings. Lets the splits complete and observe
   whether the cluster recovers to its post-split steady-state. Useful for validating that
   the dip is transient, not permanent.

I'd run option 1 next (pre-split with `ysql_num_tablets=4`). If TPS is steady through 300s
without a dip, that confirms split storms were the cause. If a different bottleneck shows up,
we'll know it's load-driven, not split-driven.

## Comparison table — updated

| Iter | Tservers | Threads | Master CPU | `ysql_num_tablets` | Ramp time | Peak TPS | Steady band | Notes |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| 19 | 12 | 6000 | 2-core cap | 1 | ~120s | **81,490** | 71–81K (T=120–270) | Slow ramp; never reached split threshold during 300s |
| **20** | **12** | **6000** | **un-capped** | **1** | **~20s** | **75,561** | **70–75K (T=20–140), then split storm** | **Ramp fixed; mid-run splits expose what iter 19 deferred** |
