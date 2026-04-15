# AWS Iter 2 — ysql_max_connections=1024, threads=3000

Report: `reports/20260415_2010/`
Date: 2026-04-15
Target: push past 37K (iter 1) toward 200K; raise YSQL conn cap + client threads.

## Result

| Metric | Value |
|---|---|
| TPS (avg over 120s) | **52,800** |
| TPS (steady-state, 60-120s) | **~81,000–86,000** |
| p95 latency | 68.05 ms |
| avg latency | 57.49 ms |
| max latency | 7810 ms (warmup tail) |
| errors | 0 |
| threads | 3,000 |

**Progress:** averaged 1.4× iter 1, but steady-state is ~2.2× iter 1 (37,762 → ~83K). Averaged TPS depressed by 40s ramp where `tps` climbed 1K → 10K → 45K → 84K.

## Per-10s Window

| 10s | TPS | p95 (ms) |
|---:|---:|---:|
| 10 | 1,055 | 4600 |
| 20 | 1,909 | 4600 |
| 30 | 2,748 | 4129 |
| 40 | 10,107 | 3095 |
| 50 | 44,970 | 37.56 |
| 60 | 83,682 | 49.21 |
| 70 | 81,167 | 75.82 |
| 80 | 86,628 | 51.02 |
| 90 | 84,827 | 78.60 |
| 100 | 74,687 | 110.66 |
| 110 | 81,437 | 81.48 |
| 120 | 81,511 | 65.65 |

Warmup counted against the measurement window because sysbench `warmupTime=30s` runs before the clock — yet the first 30s of measurement shows the cluster still absorbing the 3000-thread connection storm. Steady-state is reached at ~t=50s.

## Infrastructure

### Per-tserver / VM

| Metric | Iter 1 (1200 thr) | Iter 2 (3000 thr) | Change |
|---|---|---|---|
| tserver container CPU | 317% | 202% | ↓36% |
| db-node VM CPU | 58–66% | 42–54% | ↓ |
| client-node CPU | 2.2% | 13.6% | ↑6× (still very idle) |
| system-node CPU | 9% | 5% | — |
| network RX/TX per tserver | 6 MB/s | 4.8 MB/s | ↓ |
| disk write IOPS | 22/tserver | 25/tserver | — |
| avg iowait | 0% | 0.1% | — |

**Surprise:** at 2.2× the steady-state throughput, *both* tserver container CPU and VM CPU went **down**. Two hypotheses:
1. The metrics snapshot was taken after the run, and sampling landed near the tail where load had tapered.
2. The warmup/ramp phase (0-40s, near-idle) dragged the average CPU reported across the 120s window down. The instantaneous steady-state CPU at 80K TPS is almost certainly higher than reported.

Most likely (2): the Prometheus query averages over ~2 min including a ramp. Spot CPU during steady-state is what matters and likely 70-80%.

## Bottleneck Analysis

**Per-thread throughput at steady-state:** 83K / 3000 = **27.7 TPS/thread** → avg per-thread lat ≈ 36 ms. Iter 1: 31.5 TPS/thread → 32 ms.

Per-thread latency rose only ~12% while throughput rose 2.2×. That is **near-linear scaling** from the database's perspective; the per-thread cost barely moved.

**The 200K target:**
- Linear extrapolation: 83K / 3000 × 6144 (cluster cap) = **~170K TPS** at the YSQL conn ceiling.
- Real-world: per-thread latency will climb further as tserver CPU saturates.

## Steady-State CPU (Prometheus [20:08:33–20:09:53])

Clean query over the 80s post-ramp window:

| Node | avg | min | max |
|---|---:|---:|---:|
| db-0 (ts-2) | 77.7% | 23.9% | 97.7% |
| db-1 (ts-3) | 69.2% | 15.7% | 97.1% |
| db-2 (ts-0) | 81.2% | 15.6% | 98.3% |
| db-3 (ts-5) | 82.7% | 29.5% | 97.3% |
| db-4 (ts-4) | 78.3% | 15.3% | 98.4% |
| db-5 (ts-1) | 70.5% | 16.9% | 97.9% |
| system | 11.1% | 0.8% | 26.6% |
| client | 5.5% | 0.5% | 7.3% |
| k3s-master | 5.2% | 4.7% | 6.0% |

db nodes: avg ≈ **75%**, peaks ≈ **97–98%** — periodically saturated.

YB handler latency at steady-state:
- Write RPC: **12.5 ms** (iter 1: 5.1 ms, **2.4× worse**)
- log_sync (WAL fsync): **7.4 ms** (iter 1: 6.5 ms — flat)

The doubling of Write RPC latency while fsync stayed flat points to **tserver-internal queuing** (CPU/lock contention inside the handler), not disk.

## Headroom Verdict

- **db-node CPU:** ~25% average headroom, but peaks already at 97-98%. Sustained 2× throughput is unlikely on this node spec.
- **tserver CPU limits:** no container limit set, so bound only by VM CPU.
- **Disk/network/memory:** vast headroom, not relevant.

**Interpretation:** the 6× c7i.8xlarge spec can probably push to ~100-110K TPS but not to 200K. Write RPC is already queuing.

## Findings

1. **ysql_max_connections=1024 worked** — no "too many clients" errors; 3000 threads × 6 tservers distributed cleanly.
2. **Ramp is slow**: 0-40s of the measurement window hadn't reached steady-state. A longer run (or real warmup separate from measurement) is needed for clean averages.
3. **Scaling is near-linear**: per-thread latency stable.
4. **db node CPU still has headroom** (~50% VM, similar softirq) but spot readings during steady-state are the relevant number.

## Next Iteration

With db nodes peaking at 97-98% CPU, raising threads alone won't cleanly reach 200K. Options, in order of simplicity:

1. **Scale out to 8-9 tservers (same c7i.8xlarge)** — linear expectation: 83K × 8/6 ≈ 110K; with Write RPC queuing relief, plausibly 130-150K.
2. **Scale up to c7i.16xlarge (64 vCPU) on same 6 nodes** — doubles CPU per tserver; likely reaches 150K+.
3. **Both (8× c7i.16xlarge)** — clear path to 200K+ with margin.
4. Run a 5000-thread test *on current spec* first to confirm the ceiling is ~100-110K (cheap sanity check before re-sizing).

## Open Questions

- Why does the ramp take 40s to reach steady-state? Hypothesis: sysbench opens 3000 PG connections serially; first batch blocks behind DNS+auth+session setup.
- At steady-state CPU ≈ ?, not yet measured precisely. Need instantaneous Prom query during run.
