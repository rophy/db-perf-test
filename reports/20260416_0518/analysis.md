# Iter 14 — 6 tservers with ysql_num_tablets=12 (REGRESSION)

Report: `reports/20260416_0518/`
Date: 2026-04-16
Config: 6× c7i.8xlarge tservers (RF=3), threads=3000, warmup=90s, run=300s, **ysql_num_tablets=12** (iter 13 used default =1), trigger installed on all 24 tables.

Purpose: Test the hypothesis from iter 13 analysis that the single-tablet-per-table configuration (24 primary + 24 secondary-index raft leaders) was the steady-state bottleneck limiting TPS to ~41K.

## Result

| Metric | Iter 13 (1 tablet) | Iter 14 (12 tablets) | Δ |
|---|---:|---:|---:|
| TPS avg (300s) | 40,661 | **30,932** | **-24%** |
| TPS steady (t=30–290s) | 38K–42K | 29.6K–32.5K | -25% |
| p95 latency | 112.67 ms | **142.39 ms** | +26% |
| avg latency | 73.79 ms | 96.89 ms | +31% |
| Container CPU (sum) | 1,912% | 1,830% | -4% |
| VM CPU | 74-76% | 75-78% | ~same |
| Disk write IOPS | 163 | 261 | +60% |
| Network RX/TX | 44.7 / 44.3 MB/s | 38.9 / 38.7 MB/s | -13% |
| Errors | 0 | 0 | — |

Hypothesis falsified: adding tablets *hurt* throughput despite eliminating the "single-leader-per-table" structure.

## Why the regression

The trigger workload executes a three-step transaction per INSERT:

1. `INSERT INTO sbtest_N VALUES (...)` — writes to a primary-key tablet (hashed by `id`)
2. Trigger fires: `SELECT id FROM sbtest_N WHERE k = NEW.k AND id != NEW.id` — reads from the `k_N` secondary-index tablet (hashed by `k`)
3. Conditional `DELETE FROM sbtest_N WHERE id IN (...)` — writes to a primary-key tablet (hashed by returned `id`s)

**With 1 tablet/table:** All three ops target the same tablet leader. The INSERT, SELECT, and DELETE all execute in a single raft-commit round on one tserver. One fsync, one consensus round.

**With 12 tablets/table:** Each op's target tablet is hashed independently; the three tablets are usually on three different tservers. Each INSERT transaction becomes a distributed transaction with:
- 2PC coordination between participating tablets
- Cross-tserver RPC calls
- Multiple fsync operations (one per participating tablet's WAL)
- Extra consensus rounds

The per-transaction latency floor rose from ~74 ms → ~97 ms, so the 3,000-thread concurrency limit produced 3000/0.097 ≈ **31K TPS**, matching the observed 30,932.

## Disk IOPS as independent confirmation

Write IOPS rose **60% (163 → 261)** while total data written went **down** (network -13%). More, smaller WAL fsyncs per transaction = more tablets being touched.

## Revised bottleneck model (important)

Iter 13's 41K TPS was **latency-bound**, not CPU-bound:

```
TPS_max = threads / avg_latency
3000 / 0.074 s ≈ 40,541  (observed: 40,661)
```

CPU had 25% headroom (74-76% VM). Write RPC latency variance (9.9-21.8 ms across tservers) was a *symptom* of uneven leader placement, not the *cause* of low throughput.

**Corollary for future tuning:** adding raft leaders/tablets does not help when transactions are serial across multiple tablets. To push past 41K on 6 tservers, the levers are:
- Increase client concurrency (more threads) to fill the CPU headroom
- Reduce per-transaction latency (harder — tied to workload shape and WAL/raft round-trip)
- Scale out tservers (already verified near-linear 6→12→18)

## Next step

- Revert `ysql_num_tablets` to default (1) in values-aws.yaml
- **Iter 15 plan:** raise sysbench threads 3000 → 5000 and re-run to check if the CPU headroom converts into higher TPS

## Verdict

Hypothesis rejected. The 24-leader structure of iter 13 was near-optimal for this specific trigger workload on this cluster. Tablet count is not the right knob; client concurrency or a workload-shape change would be.
