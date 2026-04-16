# AWS Iter 6 — 18× tserver, shards=2 revert (ANOMALY: underperforms iter 4)

Report: `reports/20260416_0028/`
Date: 2026-04-16
Config: 18× c7i.8xlarge tservers (RF=3), threads=9000, warmup=120s, run=300s, `ysql_num_shards_per_tserver=2` (reverted from iter 5's 8).
Hypothesis: iter 5 falsified shard tuning; reverting to iter-4 gflags on 18 nodes should match or exceed iter 4's 185K peak.

## Result

| Metric | Value |
|---|---|
| TPS (avg over 300s) | 61,738 |
| TPS (peak 10s window) | **~121K** (t=180s) |
| TPS (steady-state, t=170–300s) | **~100–121K** (avg ~110K) |
| p95 latency | 356.70 ms |
| avg latency | 148.23 ms |
| max latency | 47,913 ms (ramp tail) |
| errors | 0 |
| threads | 9,000 |

**Unexpectedly poor**: worse than both iter 4 (185K peak at 17 nodes) and iter 5 (122K peak at 18 nodes, shards=8). Adding a node + matching iter-4 gflags was expected to give 195K+.

## Steady-State Metrics (Prometheus, t=170–300s ≈ 00:26:00–00:28:20 UTC)

| Metric | Iter 4 | Iter 5 (shards=8) | **Iter 6 (shards=2)** |
|---|---:|---:|---:|
| Tservers | 17 | 18 | 18 |
| Peak TPS | 185K | 122K | **121K** |
| DB CPU avg | 82.7% | 67% | **69%** |
| DB CPU range | 79–84% (15pp) | 48–89% (41pp) | **55–89% (35pp)** |
| log_sync avg | 6.8 ms | 6.6 ms | 6.7 ms uniform |
| Write RPC rate range (max/min) | 2.57× | 5.32× | **2.78×** |
| Write RPC latency worst | ts-5: 196 ms | ts-12: 168 ms | **ts-17: 286 ms** |
| Net RX peak / node | 4.6 Gbps | — | ~520 Mbps/node |

## Per-Tserver Load (steady-state)

### Write RPC rate (req/s)

| tserver | rate | | tserver | rate |
|---|---:|---|---|---:|
| ts-15 | 20,944 | | ts-14 | 14,614 |
| ts-10 | 17,022 | | ts-12 | 14,631 |
| ts-0 | 16,728 | | ts-17 | 14,739 |
| ts-2 | 16,537 | | ts-13 | 10,597 |
| ts-7 | 16,127 | | ts-1 | 10,566 |
| ts-11 | 14,514 | | ts-8 | 10,464 |
| ts-3 | 14,498 | | ts-9 | 10,382 |
| ts-16 | 14,349 | | ts-5 | 8,054 |
|  |  | | ts-6 | 7,987 |
|  |  | | ts-4 | **7,532** |

Mean 13,585 · range 7,532–20,944 · **max/min = 2.78×**, spread 99% of mean. Better distributed than iter 5, comparable to iter 4.

### Write RPC latency (ms)

| tserver | ms | | tserver | ms |
|---|---:|---|---|---:|
| **ts-17** | **286.46** | | ts-11 | 2.03 |
| ts-10 | 8.93 | | ts-3 | 1.74 |
| ts-12 | 6.72 | | ts-4 | 1.51 |
| ts-2 | 5.23 | | (others 2.1–4.7 ms) | |
| ts-15 | 4.68 | |  |  |

ts-17 outlier at 286 ms, again in the 168–286 ms range — **same outlier pattern, different tserver each iter** (ts-5 → ts-12 → ts-17).

### log_sync latency (uniform)

6.56–7.00 ms across all 18 tservers. Disk fine everywhere.

## Diagnosis: Why Iter 6 Underperformed Iter 4

Three candidate explanations:

**1. Fresh tablet state — tablets not yet warmed / leader balance immature.**
After helm upgrade + cleanup+prepare, each table has new tablets, leaders freshly elected. YB's leader balancer may not have reached a stable state within the 120s warmup. Iter 4 ran after tables had been in steady operation for multiple prior iters.

**2. Noisy neighbors on fresh EC2 instances.**
The cluster was torn down and rebuilt today (2026-04-16 ~23:40 UTC); new EC2 instances may share hypervisors with other tenants. c7i is shared-tenancy; steal time in metrics is 0% but latency variance (ts-17 at 286 ms alone) and CPU spread (35pp vs iter 4's 15pp) suggest per-instance contention.

**3. Manual k3s agent join left kernel/sysctl defaults.**
Per provisioner note: cloud-init user_data did not run; workers joined via manual `k3s-agent` install. If the original path set sysctls (tcp_max_syn_backlog, somaxconn, fs.file-max, etc.), those may be missing now. Not directly measurable without comparing /etc/sysctl.d/ between iter-4 and iter-6 nodes.

The ts-17 latency outlier (286 ms at only 14.7K req/s) is consistent with #2 — one pod stuck on a slow CPU/memory/network path while doing moderate work. Disk is uniform (log_sync ~6.7 ms), so it's not EBS.

## Full Scaling History

| | Iter 1 | Iter 2 | Iter 3 | Iter 4 | **Iter 5** | **Iter 6** |
|---|---:|---:|---:|---:|---:|---:|
| Tservers | 6 | 6 | 12 | 17 | 18 | **18** |
| Threads | 1,200 | 3,000 | 6,000 | 8,500 | 9,000 | 9,000 |
| Shards | 2 | 2 | 2 | 2 | 8 | **2** |
| Peak TPS | 37.8K | 86.6K | 153.8K | **185.6K** | 122.7K | **121.2K** |
| Steady TPS | 37.8K | ~83K | ~140K | **~168K** | ~115K | ~110K |
| p95 (ms) | 41.9 | 68 | 177 | 240 | 298 | 357 |
| db CPU avg | 62% | 75% | 75% | **82.7%** | 67% | 69% |
| db CPU range | — | — | — | 15pp | 41pp | 35pp |
| Write RPC avg (ms) | 5.1 | 12.5 | 17.4 | 24.2 | ~3 (hot), 168 outlier | ~3, 286 outlier |
| log_sync (ms) | 6.5 | 7.4 | 7.0 | 6.8 | 6.6 | 6.7 |

## Implication

**Iter 6 is not a meaningful datapoint for shard-tuning conclusions.** It should match or beat iter 4 on same gflags + 1 extra node; it doesn't, so something else regressed on this cluster rebuild. The 200K+ target cannot be chased further without first regressing the cluster back to a known-good baseline.

Recommended next steps (NOT executed this session):
1. Check sysctl parity between iter-4 nodes (already destroyed) and current via EC2 user_data rerun or manual diff against kube-sandbox source.
2. Re-run iter 4 config (17 tservers, threads=8500, warmup=90, time=300) on *this* cluster to see if the regression reproduces at iter-4 load.
3. If it reproduces, the cluster build path (manual k3s-agent) is the confound and future runs need the cloud-init path restored.

## Verdict

**200K not achieved.** Iter 4 remains the best result (185K peak, 168K steady on 17 nodes). Iter 5 and iter 6 on 18 nodes both underperformed — one due to shard-tuning regression, one due to unexplained cluster-rebuild regression. The 200K wall is real but the ceiling on the current AWS setup is still 185K until the rebuild regression is understood.

Cluster being stopped (not destroyed) per user request to preserve state for future diagnosis.

## Post-run: kubelet tunnel broken (additional rebuild evidence)

Attempting to port-forward Prometheus for deeper metrics (~00:40 UTC, ~12 min after run) consistently returned:

```
error: error upgrading connection: error dialing backend:
  proxy error from 127.0.0.1:6443 while dialing 10.0.1.42:10250, code 502: 502 Bad Gateway
```

Reproduced across all worker nodes (system, tserver-0 on ip-164, tserver-5 on ip-132). Only apiserver LIST/GET (watch cache) works; `exec`, `logs`, `port-forward` all fail because the apiserver→kubelet tunnel (port 10250) is down.

Pods remained `Running Ready` throughout. This is almost certainly a consequence of the manual k3s-agent join path on this rebuild — cloud-init user_data did not execute, so kubelet serving certificate / bootstrap token may not have been established the way the master expects. It reinforces the iter-6 hypothesis: **this cluster is subtly misconfigured at the k3s layer**, and any performance numbers from it should be treated as lower-bound.

No additional live metrics could be collected before cluster stop.
