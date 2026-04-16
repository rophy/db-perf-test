# Iter 21 — auto-split disabled removes the mid-run dip; clean steady-state at ~73K TPS

Report: `reports/20260416_1149/`
Date: 2026-04-16
Config: 12× c7i.8xlarge tservers (RF=3), threads=6000, warmup=90s, run=300s,
2× system nodes hosting 3 yb-masters (un-throttled).
**Changed vs iter 20**: `enable_automatic_tablet_splitting=false` on both master and tserver gflags.

## Hypothesis under test

Iter 20 found that the mid-run TPS dip (75K → 17K at T=260) coincided with a `not_leader_rejections`
spike (0 → 7,703/s at T=240, 23,933/s at T=390) and a cluster leader-count drop (~125 → ~92).
Diagnosis: automatic tablet splits triggered mid-run as tables crossed the size threshold; split
storms briefly removed leaders and rejected writes.

If correct, disabling auto-split should give a flat, dip-free steady-state for the full 300s run.

## Result — hypothesis CONFIRMED. Flat 66–77K TPS through entire run.

### Sysbench per-interval TPS — no mid-run dip

Direct comparison at same wall-clock T (post-warmup only):

| T(s) | Phase | Iter 20 TPS | Iter 21 TPS |
|---:|:---|---:|---:|
| 100 | run | 73,100 | 73,183 |
| 140 | run | 62,033 | 74,421 |
| 180 | run | 51,899 | 75,872 |
| 200 | run | 40,632 | 73,559 |
| 240 | run | 40,623 | 73,162 |
| **260** | run | **16,707** | **72,140** |
| 280 | run | 34,301 | 71,558 |
| 300 | run | 44,772 | 70,980 |

Iter 21 stays in a tight 66–77K band for the entire run window. Iter 20 collapsed to 17K at T=260.

### DB-side Write RPC rate — rock-stable

| T(s) | Iter 20 WrRPC/s | Iter 21 WrRPC/s |
|---:|---:|---:|
| 90 | (peak ~260K) | 263,103 |
| 150 | (declining) | 233,530 |
| 240 | 92K (split storm) | 246,648 |
| 300 | recovering | 241,722 |
| 360 | — | 242,718 |

Cluster-wide writes hold at 230–260K/s throughout — confirming the sysbench TPS plateau
isn't a reporter artifact.

### `not_leader_rejections` — orders of magnitude smaller, but non-zero

| T(s) | Iter 20 /s | Iter 21 /s |
|---:|---:|---:|
| 120 | <100 | 515 |
| 240 | **7,703** | 318 |
| 270 | 3,605 | 8 |
| 300 | 778 | 103 |
| 360 | 11,725 | 21 |
| **390** | **23,933** | **59** |

Iter 21 peak is 515/s vs iter 20 peak of 23,933/s — a 46× reduction. Some leader churn still
exists (likely the cluster's leader load balancer redistributing leaders across the 12 tservers
under heavy write load), but it's small enough that it never registers as a TPS dip.

### Cluster leader count — drops, but doesn't disrupt throughput

| T(s) | Iter 20 leaders | Iter 21 leaders |
|---:|---:|---:|
| 0–180 | ~125 | 152 (flat) |
| 240 | ~125 | 97 |
| 300 | ~127 | 85 |
| 360 | ~92 (split storm) | 79 |

Iter 21's leader count drops from 152 → 79 over T=210–360. Auto-split is OFF, so this isn't
new tablets being created. Most likely the leader load balancer consolidating (the cluster
started with 152 leaders right after a fresh deploy/restart — uneven distribution from
startup). Crucially, **TPS and Write RPC stay flat through this rebalance** — leader moves
under steady load are non-disruptive when no splits are happening.

## Verdict

Auto-split disable definitively explains iter 20's mid-run TPS dip:

- **No dip**: Iter 21 sustains 66–77K TPS for the entire 300s run.
- **No leader storms**: Peak `not_leader_rejections` is 515/s vs iter 20's 23,933/s.
- **Steady DB-side writes**: 230–260K WrRPC/s throughout, no mid-run drop.

Run-averaged TPS rose from 56,584 → 73,047 (+29%), but the more important comparison is
**steady-state**: iter 20 averaged ~50K post-T=140, iter 21 averaged ~73K. The 23-point
gap is what the splits cost in iter 20.

Note: peak TPS still landed at ~76K — same as iter 20's pre-split peak. The cluster has not
gained ceiling, only stability. The 95% DB CPU during steady state suggests CPU is the
primary bottleneck, not splits. Splits weren't a ceiling problem; they were a tail problem.

## What this is NOT yet

- **Not production-ready**: auto-split exists for good reason (hot tablets need to subdivide).
  Disabling it for the full benchmark is a diagnostic, not a recommendation.
- **Not a peak-TPS win**: peak is ~unchanged. The steady-state win comes from removing the
  collapse, not raising the ceiling.
- **Open question**: cluster leader count drops 152 → 79 during the run with no auto-split
  and no TPS impact. Worth understanding (likely LB consolidation from uneven post-restart
  distribution) but not a blocker.

## Recommended next steps

The "splits caused the dip" question is settled. Two natural follow-ups:

1. **Pre-split tablets** with `ysql_num_tablets` (e.g. 4 or 8) and re-enable `enable_automatic_tablet_splitting=true`.
   This is the production-shaped equivalent: provision enough tablets up-front so the run never
   crosses the auto-split threshold, but keep auto-split on as a safety net. Note: iter 14 saw
   a 24% regression at `ysql_num_tablets=12` (6 tservers, ingest-saturated). With 12 tservers,
   a moderate 4–8 may land in the sweet spot.
2. **Investigate the 95% DB CPU ceiling**. With splits removed, CPU is now the bottleneck. Profile
   tserver hot paths during steady-state (e.g. flame graph one of the tservers) to understand
   whether it's RocksDB compaction, RPC handling, or PG-layer overhead.

I'd run option 1 next — it's the closer-to-production answer and directly addresses the
"can we reach iter 19's 81K peak without the mid-run dip" question.

## Comparison table — updated

| Iter | Tservers | Threads | Auto-split | Ramp | Peak TPS | Steady band | Notes |
|---|---:|---:|:---:|---:|---:|---:|---|
| 19 | 12 | 6000 | on | ~120s | **81,490** | 71–81K (T=120–270) | Slow ramp deferred splits past run window |
| 20 | 12 | 6000 | on | ~20s | 75,561 | 70–75K then collapses to 17K | Fast ramp triggered mid-run split storm |
| **21** | **12** | **6000** | **off** | **~20s** | **76,127** | **66–77K (T=20–300, flat)** | **No splits, no dip, clean steady-state** |
