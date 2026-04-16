# Iter 19 — 12 tservers reach 81K peak; "40K ceiling" framing from iter 13–18 disproved

Report: `reports/20260416_1007/`
Date: 2026-04-16
Config: 12× c7i.8xlarge tservers (RF=3), threads=6000, warmup=90s, run=300s, `ysql_num_tablets` default (1), trigger on all 24 tables, `rpc_workers_limit` default (no override).

This is the first run using the new `sysbench_times.txt` + per-interval-table format
(commit `4f45c4a`), so steady-state numbers are read directly from the post-warmup rows
rather than averaged across warmup+run.

## Purpose

Two goals:

1. **Reproduce iter 12's 81K peak on 12 tservers** under the new reporting pipeline. Iter 12's
   number was suspect because all iter 13–18 analyses had been built on a flat-averaged CPU
   metric that buried the warmup ramp inside the "average" — see
   `~/.claude/projects/-home-rophy-projects-db-perf-test/memory/project_cpu_avg_artifact.md`.
2. **Test whether the "40K coordinator-bound ceiling" hypothesis from iter 13–18 survives
   honest measurement** at 12 tservers with the same workload shape.

## Result — iter 13–18 framing FALSIFIED

Per-interval table (excerpt from `summary.txt`):

| T(s) | Phase | TPS | p95(ms) | DB CPU% | Net MB/s | WrIOPS |
|---:|:---|---:|---:|---:|---:|---:|
| 90 | warmup | 11,479 | 6247 | 8.0 | 76 | 109 |
| 100 | run | 36,262 | 34 | 8.3 | 56 | 85 |
| 120 | run | 80,534 | 183 | 9.1 | 49 | 105 |
| **130** | **run** | **81,490** | **272** | **9.4** | **79** | **75** |
| 180 | run | 75,232 | 293 | 15.5 | 124 | 126 |
| 220 | run | 73,904 | 326 | 93.2 | 1,166 | 1,525 |
| 270 | run | 74,143 | 443 | 95.5 | 946 | 1,332 |
| 280 | run | 61,125 | 249 | 94.8 | 1,081 | 1,453 |
| 290 | run | 37,734 | 405 | 93.7 | 885 | 2,106 |
| 300 | run | 32,915 | 159 | 95.1 | 1,037 | 2,263 |

| Headline | Value |
|---|---:|
| **Peak TPS (T=130)** | **81,490** |
| Steady-state band (T=120–270) | 67K–81K, mostly 71–77K |
| Run-averaged TPS (sysbench reports) | 48,194 ← *includes warmup, do not cite* |
| p95 latency (run-avg) | 357 ms |
| Errors | 0 |

**Iter 12's 81K peak reproduces under the new pipeline.** That alone disproves the
"6 tservers can't push past 40K because of a coordinator critical path" model that
iter 13–18 had converged on — at 12 tservers the same workload sustains ~75–80K with a
peak of 81.5K, which is **1.87× the 6-tserver ~40K** number. That is **near-linear scale-out**.
A structural per-transaction critical path would not scale that way.

## What the iter 13–18 model got wrong

Iter 13–18 analyses cited a run-averaged 6-tserver CPU of ~72.8% and concluded the cluster
had headroom that wasn't being used — therefore the cap had to be a serial software
critical path. That CPU number was a **warmup-averaging artifact**: the steady-state
CPU on the 6-tserver cluster was actually 99% (per `project_cpu_avg_artifact.md`).

With steady-state CPU at 99% on 6 tservers, the right reading of iters 13–18 is simpler:
**the 6-tserver cluster was CPU-saturated**, and adding tservers lifts throughput
proportionally. There is no "coordinator-bound 40K ceiling." Iter 19 confirms this directly.

## What about the tail "collapse" at T=280–300?

The per-interval table shows sysbench-reported TPS dropping 61K → 37K → 33K in the last
30 seconds. Initial reading was "disk-/compaction-bound at the tail." Direct Prometheus
drilldown disproves that:

| Metric checked | T=270 (steady) | T=290 (during "collapse") | Reading |
|---|---:|---:|---|
| `active_background_compaction_input_bytes_added - removed` | ~0 GB | ~0 GB (0.08 GB blip at T=280; 0.9 GB after sysbench ended) | No compaction debt |
| `node_disk_io_time_seconds_total` rate | 8% busy max | 8% busy max | Disk not saturated |
| `log_sync_latency` (WAL fsync) | 7 ms | 7 ms | Plateaued, not degrading |
| `handler_latency_yb_tserver_TabletServerService_Write_count` rate, sum across tservers | 249K writes/s | 231K writes/s | **Only -7%** vs **-49%** sysbench TPS |
| Client node CPU (32-core c7i.8xlarge) | 12% avg / 25% per-CPU max | same | Client not bottleneck |

Per-tserver Write RPC rate dropped 7% while sysbench-reported TPS dropped 49%. The
DB-side write workload was nearly steady; the **collapse exists in the sysbench reporter,
not in the cluster**.

The most plausible explanation: long-tail latency (max 24.5 s observed in totals) means
in-flight transactions don't complete inside sysbench's 10-second `--report-interval`
window. Sysbench reports completed-in-window, so its TPS line drops while the DB keeps
writing at the same rate.

## NEW finding — yb-master leader was CPU-throttled at its 2-core cgroup limit

Discovered while drilling into why DB CPU on the tservers ramped slowly (it stayed at
8–15% from T=100 to T=180 even though the workload was already pushing 75–81K TPS).

All 3 yb-masters land on a single system node:

| | |
|---|---|
| Node | `ip-10-0-1-42.ap-east-2.compute.internal` (role=system) |
| Spec | **8 CPU / 16 GB** (c6i.2xlarge) |
| Co-tenants | 3× yb-master, prometheus, node-exporter, coredns, ebs-csi-node |
| Per-master container limits | **cpu=500m–2, mem=1Gi–4Gi** |

Per-container CPU (filtering `container!=""` to avoid pod-level double-counting):

- **yb-master-1** (the leader): pinned at **exactly 2.00 cores** from T≈30 to T≈200 — that's
  the cgroup ceiling, not a coincidence. Drops to 0.08 cores at T≈230.
- yb-master-0, yb-master-2: ~0 cores throughout.

The earlier iter-19 memory note said "master-1 burned 4 cores"; that figure came from a
pod-level Prometheus query that double-counted the shared `container=""` pause series.
The corrected number is **2.0 cores hard-capped**, hitting the limit during the entire
ramp.

This likely explains the 100s ramp (T=100 → T=200) where tservers sat at 8–15% CPU despite
already serving 75K+ TPS: the leader master was CPU-saturated doing tablet-split / heartbeat
/ catalog work as 14.5M rows × 24 tables were ingested. Once master work fell off
(T=230, master-1 → 0.08 cores), tservers ramped to 95% and held.

The ramp behavior was **not** the workload converging on the cluster's natural steady-state;
it was the master leader unblocking it.

## Per-tserver write rate asymmetry — open question

Some tservers (yb-tserver-7, 8, 9, 11) consistently sustained ~30% lower write rate than
others (yb-tserver-2, 4, 5, 10). Could be the YB load-balancer primary/index segregation
issue documented in iter 16/17 — at 12 tservers it would split into two trios of 6, with
primaries on one half and indexes on the other. Not investigated this run.

## Updated historical TPS table

| Iter | Tservers | Threads | Placement | Peak TPS | Steady TPS | Notes |
|---|---:|---:|---|---:|---:|---|
| 11 | 18 | 8500 | default (LB) | 107K | 100K | Near-linear scale-out |
| 12 | 12 | 6000 | default (LB) | 81K | 75K | 1.85× over 6 |
| 13 | 6 | 3000 | default (LB) | 44K | 41K | "Baseline" — actually CPU-saturated, framing was wrong |
| 14 | 6 | 3000 | default, 12 tablets/table | — | 31K | Regressed |
| 15 | 6 | 5000 | default (LB) | — | 34K avg / 40K steady | Past Little's Law knee |
| 16 | 6 | 5000 | default, `rpc_workers_limit=2048` | — | 34K avg / 40K steady | Pool wasn't the cap |
| 17 | 6 | 5000 | manually interleaved | — | 34K avg / 40K steady | Physical balance not the cap |
| 18 | 6 | 3300 | default (LB) | — | 39K | Past knee |
| **19** | **12** | **6000** | **default (LB)** | **81,490** | **71–77K** | **Reproduces iter 12; falsifies "40K ceiling"** |

## Verdict

1. **Iter 12's 81K peak is real and reproducible.** The 6→12 scaling is ~1.87× — near-linear.
2. **The "coordinator-bound 40K ceiling" framing from iter 13–18 is wrong.** It was built
   on a CPU-averaging artifact (`project_cpu_avg_artifact.md`); the 6-tserver cluster
   was actually CPU-saturated at steady state.
3. **The tail TPS "collapse" is largely a sysbench reporter artifact**, not a real cluster
   collapse — DB-side Write RPC rate dropped only 7% during the 49% TPS dip.
4. **NEW: yb-master leader was CPU-throttled at its 2-core cgroup limit** for the entire
   T=30–200 ramp. This is the most likely cause of the slow tserver-CPU ramp (8% → 95%)
   and is not a property of the workload — it is a property of the deployment limits.

## Recommended next steps

1. **Raise the yb-master CPU limit** (e.g. 2 → 6 cores; system node has 8 CPU and other
   tenants are quiet) and re-run iter 19. Hypothesis: tserver CPU ramps faster, and either
   (a) peak TPS lifts, or (b) we see the *actual* 12-tserver steady-state without ramp
   blocking.
2. **Stop citing iter 13–18 run-averaged TPS** as evidence of a structural cap. The
   per-interval table is the source of truth from now on.
3. **Run iter 19 longer (600s+)** to distinguish "steady at 75K" from "real degradation"
   independently of the sysbench report-interval artifact.
4. **Investigate per-tserver Write RPC asymmetry** at 12 tservers — is the LB
   primary/index segregation also splitting 12 into two 6-trios?
5. **Do not retro-fit iter 13–18 conclusions onto iter 19.** The CPU-averaging artifact
   contaminated the entire iter 13–18 reasoning chain; treat those iterations as
   methodologically void rather than as a "ceiling" to compare iter 19 against.
