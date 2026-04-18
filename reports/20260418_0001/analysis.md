# Iter 24 — 57× c7i.4xlarge: 89K TPS bottlenecked by 24-tablet transactions table

## Config
- **Cluster:** 57× c7i.4xlarge tservers (16 vCPU / 32 GB each), 3 masters on c7i.4xlarge (uncapped CPU), RF=3
- **Cluster history:** initially created at 24 tservers, then scaled out to 57 before the run
- **Workload:** oltp_insert + cleanup_duplicate_k trigger, 24 tables, 2 sysbench pods × 10,500 threads = 21K total, 300s run + 90s warmup
- **Changed vs iter 23:** 57 tservers (was 14), c7i.4xlarge (was c7i.16xlarge, 64 vCPU), 21K threads (was 12K)
- **gflags:** auto-split disabled, ysql_num_shards_per_tserver=2, ysql_max_connections=1000, `transaction_table_num_tablets` left at default (auto)
- **AWS cost:** ~$39 for the cluster lifecycle (62× c7i.4xlarge × ~0.9hr × $0.70/hr + 1× t3.xlarge master). Most of this was sunk into a failed restart attempt — after the run, tservers were stopped to save money, but ap-east-2 didn't have c7i.4xlarge capacity to restart all 57 (only 25 came back), so the cluster was destroyed without re-validating the fix. Future runs will move to ap-southeast-1 (Singapore) for deeper capacity.

## Hypothesis
Smaller instances (16 vCPU) might be more efficient per-vCPU than 32 or 64 vCPU, since the trend
showed 214 TPS/vCPU at 32-vCPU vs 142 at 64-vCPU. With 57 tservers × 16 vCPU = 912 total vCPU,
target 200K TPS.

## Result — 89K TPS at 55% cluster CPU

### Per-interval steady-state (T=100-300, run phase)

| Metric | Value |
|--------|-------|
| Steady-state TPS range (combined) | 79K-95K |
| Steady-state TPS avg (combined) | ~89K |
| Peak TPS (combined, T=110) | 95K |
| p95 latency | 20-148ms (oscillating) |
| Errors | 0 |
| Total DB CPU (57 tservers) | 499 cores / 912 available = **55%** |
| Per-tserver CPU range | 3.9-13.4 cores (24-84% of 16) |
| Client (sysbench) CPU | 0.5-2.8 cores — NOT bottleneck |
| DB node CPU avg | 69% |
| DB node CPU hottest | 90.6% (tserver-44's node) |

The hypothesis is *not falsified by this run*: this cluster was created at 24 tservers and
scaled out to 57, which (as the root cause section shows) leaves coordinator work concentrated
on the original 24 tservers. The per-vCPU efficiency comparison vs prior iters is unfair —
those clusters were each created at their target size.

## Root cause: `system.transactions` has only 24 tablets on a 57-tserver cluster

Master gflags read live from `/varz`:
```
--transaction_table_num_tablets=0           (auto)
--transaction_table_num_tablets_per_tserver=8
```

Master UI (`/table?id=<txn_uuid>`) shows the `system.transactions` table has **24 tablets**
total — exactly matching the 24-tserver size at cluster creation. The transactions table is
sized once, at table creation, from the then-current tserver count. YB does **not** re-shard
it when the cluster scales out (and `system.transactions` does not auto-split — see the
upstream caveat in the rebalancing section below). The 33 tservers added during scale-out
inherit zero status tablet leadership and therefore zero coordinator work share.

## Per-tserver work distribution (Prometheus, steady-state T=100-300)

### CPU spread
- Top 5: 13.4, 13.0, 12.5, 12.2, 11.6 cores
- Bottom 5: 5.2, 5.1, 4.6, 4.5, 3.9 cores
- Spread: **3.4×** across nominally identical 16-vCPU tservers

### Write RPC rate (data tablet leader work)
- 47 tservers at ~6,150/s — uniform single-data-leader baseline
- tserver-2 outlier at 12,293/s — hosts 2 data leaders
- 1 partial tserver, 9 with no data leader

### UpdateTransaction rate (transaction coordinator work) — three distinct tiers
- **HOT-U (24 tservers, ~20K/s each):** host status tablet leaders → bear all coordinator work
- **COLD-U (28 tservers, ~3.7K/s each):** host status tablet followers → only Raft replication side
- **IDLE-U (5 tservers, <500/s):** no status tablet replicas at all
- Total: 570K/s (= 6.4 UpdateTxn per user transaction)

### Cross-tab of role × CPU × work

| Role                       | Count | Write/s avg | UpdTxn/s avg | CPU avg | CPU range  |
|----------------------------|-------|-------------|--------------|---------|------------|
| data leader + HOT-U status | 19    | 6,200       | 20,000       | 11.2    | 9.8-13.3   |
| data leader + cold status  | 28    | 6,150       | 3,720        | 9.5     | 7.9-11.2   |
| no-data + HOT-U status     | 5     | 0           | 16,400       | 6.8     | 6.2-7.6    |
| double data leader         | 1     | 12,293      | 7,420        | 11.2    | —          |
| idle (followers only)      | 4     | 0           | 0            | 5.0     | 3.8-6.1    |

The CPU spread is driven by the HOT-U status work, not data leader work. Pure-coordinator
tservers (`no-data + HOT-U`) burn 1.8 cores extra over idle tservers despite serving zero
client writes — that's the marginal coordinator cost of ~16K UpdateTxn/s.

### tserver-44 pathological outlier
- Write RPC latency: **2,965 ms** (vs 1.6ms median)
- UpdateTransaction latency: **556 ms** (vs 1.4ms median)
- WAL sync: 6.6 ms (normal)
- Node CPU: **90.6%** — CPU-saturated
- Same outlier pattern seen in every prior iteration (ts-5, ts-12, ts-17, ts-2 previously),
  but worse here because 16-vCPU saturates faster under combined data-leader + HOT-U coordinator load

## Why 55% cluster CPU at the 89K ceiling?

The cluster has 413 idle cores (912 - 499). The idle capacity sits on tservers that host
only follower replicas — they receive Raft replication traffic but never act as transaction
coordinators or data tablet leaders, so adding more user load doesn't recruit them.

The binding constraint is the **hottest transaction coordinator** (tserver-44 at 90.6% node
CPU, 13.4 container cores). Transactions whose status tablets land on this node queue behind
each other, and there's no mechanism to spread that work to the 33 idle-on-coordinator-work
tservers without re-sharding `system.transactions`.

## Prometheus queries used (run during steady-state, T=100-300)

All queries executed via `kubectl exec` into the prometheus pod:
```bash
PROM=$(kubectl --context kube-sandbox -n yugabyte-test get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}')
kubectl --context kube-sandbox -n yugabyte-test exec $PROM -- wget -qO- "http://localhost:9090/api/v1/query?query=..."
```

### Per-node CPU utilization
```promql
100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[60s])) by (instance))
```
Result: avg 69%, hottest 90.6% (ip-10-0-1-152, hosting tserver-44)

### Per-tserver container CPU
```promql
sum(rate(container_cpu_usage_seconds_total{namespace="yugabyte-test",pod=~"yb-tserver.*",container!=""}[60s])) by (pod)
```
Result: total 499 cores / 912, range 3.9-13.4 cores per tserver

### Write RPC rate and latency per tserver
```promql
# Rate
rate(handler_latency_yb_tserver_TabletServerService_Write_count[60s])
# Avg latency (µs → ms)
rate(handler_latency_yb_tserver_TabletServerService_Write_sum[60s])
  / rate(handler_latency_yb_tserver_TabletServerService_Write_count[60s]) / 1000
```
Result: total 297K writes/s, median latency 1.6ms, tserver-44 outlier at 2,965ms

### UpdateTransaction rate and latency per tserver
```promql
# Rate per tserver
sum(rate(handler_latency_yb_tserver_TabletServerService_UpdateTransaction_count[60s])) by (exported_instance)
# Cluster avg latency
sum(rate(handler_latency_yb_tserver_TabletServerService_UpdateTransaction_sum[60s]))
  / sum(rate(handler_latency_yb_tserver_TabletServerService_UpdateTransaction_count[60s])) / 1000
```
Result: 570K/s total (6.4 per user txn), avg 20.4ms, tserver-44 at 556ms

### WAL sync latency
```promql
rate(log_sync_latency_sum{exported_instance=~"yb-tserver-44"}[60s])
  / rate(log_sync_latency_count{exported_instance=~"yb-tserver-44"}[60s]) / 1000
```
Result: 6.6ms on tserver-44 (normal), uniform 6.4ms cluster-wide

### Leader distribution
```promql
sum(is_raft_leader) by (exported_instance)
```
Result: 107 total leaders (~2 per tserver, uniform). Of these: 48 data tablet leaders
(24 primary + 24 index) and 24 status tablet leaders + system table leaders.

### Not-leader rejections
```promql
sum(rate(not_leader_rejections[60s]))
```
Result: 40/s (no split storm)

### Network receive per tserver
```promql
sum(rate(container_network_receive_bytes_total{namespace="yugabyte-test",pod=~"yb-tserver.*"}[60s])) by (pod)
```
Result: total 1,080 MB/s, range 6.4-28.3 MB/s per tserver

### Read RPC rate
```promql
sum(rate(handler_latency_yb_tserver_TabletServerService_Read_count[60s]))
```
Result: 363K reads/s

## Verdict — load imbalance is the binding constraint

What's actually unbalanced:
1. **Status tablets: 24 leaders on 24 of 57 tservers** — root cause, fixable via gflag at deploy time
2. **Data tablets: 48 leaders on 47 tservers** — mostly even, except tserver-2 with 2× load
3. **Idle capacity: 9 tservers (4 no-leaders + 5 status-only)** contribute nothing or little

If the 24 hot status tablets were spread to ~171 tablets across 57 tservers (3 per tserver),
each tserver would do ~3.3K UpdateTxn/s instead of 20K, and the hottest node should drop
from 13.3 cores to roughly 9-10 cores — opening real headroom on the bottleneck.

## Recommended next experiments (priority order)

1. **Set `--transaction_table_num_tablets=171` on masters BEFORE deploying** (3 per tserver
   × 57 = 171). Pre-sizing at creation time is the only supported way to start with a
   well-distributed status tablet table. Highest-leverage change. Expectation: coordinator
   work spreads ~7× more evenly; hottest tserver CPU drops; total TPS rises toward the
   200K target.

2. **Investigate the data leader doubling on tserver-2.** Why did the LB place 2 data
   leaders on one tserver while 10 tservers have zero? May correlate with the YB-LB
   primary/index segregation pattern documented in prior memories.

3. Only after balancing is achieved, revisit whether the workload reaches 200K TPS. If
   balanced 57× c7i.4xlarge still tops out, evaluate workload-shape changes (colocation,
   trigger removal, YCQL) as next levers.

## Challenges with rebalancing after scale-out (out of current scope)

Researched the official YB workflow for adding nodes to a running cluster
(`docs.yugabyte.com/.../node-addition`, yb-admin reference, GitHub #10427):

- **Data tablets** rebalance automatically when nodes are added. The YB load balancer
  creates replicas on new nodes, bootstraps them async, and re-elects leaders for even
  distribution. This part Just Works.
- **`system.transactions` does NOT auto-grow on scale-out.** YB explicitly states:
  *"The txn status tablet cannot be split, so it's important we don't create too few
  tablets for it"* (yugabyte-db#10427). The `add_transaction_tablet` yb-admin command
  exists to add tablets one-at-a-time post-hoc, but there is no automatic re-shard, and
  the official "adding nodes" docs make no mention of needing to do this.
- **`split_tablet` does NOT work on `system.transactions`.** The supported post-deploy
  command is `add_transaction_tablet <table-id>`, called repeatedly (e.g. 168 times to
  grow 24 → 192).

For our current goal — **finding the max sustained TPS for this workload** — dynamic
add-node is out of scope. Every iter creates a fresh cluster at the target tserver count,
with the right gflags baked in. Validating the scale-out workflow (and the
`add_transaction_tablet` rebalance recipe) is a separate experiment for a separate day.

## Implications for 200K TPS

Earlier runs (6, 12, 18 tservers) were each created fresh at their target size, so their
transactions tables were sized to match — every tserver got coordinator work. The 57-tserver
run is the first where the cluster grew *after* table creation, and it's the only one
showing this skew pattern. The "scale-out wall" suggested by iter 24's flat ~89K TPS is
specific to this scale-out path, not to the 57-tserver target itself.

**Next attempt: deploy a fresh 57-tserver cluster with `transaction_table_num_tablets=171`
in the master gflags from boot.** If a balanced coordinator layer lifts 57× c7i.4xlarge
into the 120K+ range, the 200K target is back on the scale-out path. If it doesn't, then
the per-vCPU efficiency comparison from the hypothesis becomes a fair test, and we revisit
instance-size tradeoffs from there.
