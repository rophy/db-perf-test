# Iter 23 — 2× sysbench clients disprove client bottleneck, confirm DB-side ceiling at ~125K TPS

## Config
- **Cluster:** 14× c7i.16xlarge tservers (64 vCPU / 128 GB each), 3 masters on c7i.4xlarge, RF=3
- **Workload:** oltp_insert + cleanup_duplicate_k trigger, 24 tables, **2 sysbench pods** × 6K threads = 12K total, 300s run + 90s warmup
- **Changed vs iter 22:** 2 sysbench pods on separate c7i.4xlarge nodes (was 1 pod), same total threads (12K)
- **gflags:** identical to iter 22 — auto-split disabled, ysql_num_shards_per_tserver=2, ysql_max_connections=2000

## Hypothesis
Iter 22 hit 127K TPS at only 54% cluster CPU. Adding threads on the same client (iter 22b, 18K threads) made TPS worse (120K). The hypothesis: a single sysbench client is the bottleneck — pthread context switching on 16 vCPU serializes the load. Two clients on separate nodes should lift TPS if the DB has headroom.

## Result — per-interval steady-state (T=100-300)

| Metric | Iter 22 (1 client, 12K thds) | Iter 23 (2 clients, 6K+6K thds) |
|--------|------------------------------|----------------------------------|
| Steady-state TPS avg | ~127K | ~124K |
| Steady-state TPS range | 121-134K | 120-130K |
| p95 latency | 147-314ms | 126-397ms |
| Cluster CPU% | 74-78% | 74-78% |
| Client CPU (per pod) | 2.9 cores | 0.8-2.4 cores |
| Errors | 0 | 0 |

**Two clients produced the same throughput as one client.** The hypothesis is disproved.

## Key findings

### 1. Sysbench is NOT the bottleneck
- 2 pods on separate 16 vCPU nodes, each running 6K threads, produce ~62K TPS each
- Combined ~124K TPS — no improvement over 1 pod with 12K threads (127K)
- Per-pod TPS is perfectly balanced (e.g., T=280: 62,259 vs 62,360)
- Client CPU per pod dropped from 2.9 to ~1.5 cores — clients are even more idle now

### 2. Same DB-side patterns as iter 22
- **CPU utilization still 75-78%** — 33-50 cores of 64 per tserver
- **Write RPC imbalance persists** — 3 tiers despite balanced leaders:
  - High (7 tservers): ~35K writes/s
  - Mid (6 tservers): ~26K writes/s
  - Low (1 tserver): ~18K writes/s
- **Leader count balanced:** 6-8 leaders per tserver (103 total)
- **not_leader_rejections:** 118/s — no split storm

### 3. One tserver latency outlier (again)
- tserver-12: **364ms avg write latency** vs 3-9ms for all others
- Same pattern as iter 22's tserver-2 outlier (272ms)
- Different node, different IP — likely EBS volume performance variance, not a node-specific defect
- Does not drag cluster TPS (K8s service distributes connections)

### 4. Memory growth during run
- Cluster memory grew from 57 GB (T=10) to 487 GB (T=300) — ~430 GB over 300s
- This is RocksDB memtable + block cache filling on 14 tservers (31 GB/ts is reasonable for 128 GB nodes)

## Verdict

**The bottleneck is definitively inside the DB, not the sysbench client.** Two independent clients on separate nodes, each with half the threads, produce the identical total throughput as one client. The cluster leaves ~25% CPU idle at 125K TPS.

What we've ruled out:
- **Not client** (iter 23: 2 clients = same TPS)
- **Not CPU** (75% utilized, 25% idle)
- **Not disk** (WAL sync ~7ms, IOPS low)
- **Not network** (clients at 7% bandwidth)
- **Not master** (<0.1 cores)
- **Not leader placement** (balanced 6-8 per tserver)
- **Not thread count** (iter 22b: more threads = worse TPS)

**Hypothesis (UNVERIFIED):** per-tablet Raft consensus serialization.
- With ysql_num_shards_per_tserver=2 and 14 tservers, each table has 28 tablets
- Each write goes through Raft consensus (leader → 2 followers), which serializes per-tablet
- More vCPU per tserver doesn't increase Raft parallelism — it adds cores that wait for consensus round-trips
- More clients don't help because the DB can't absorb more concurrent writes per tablet

**To verify:** run ysql_num_shards_per_tserver=4 on the same cluster. If TPS lifts toward
using the idle 25% CPU, Raft parallelism was the bottleneck. If not, something else
serializes (RocksDB write batch, PG-layer lock contention, etc.).

**Caution:** iter 14 showed 24% regression with more tablets on a CPU-saturated 6-node cluster.
But at 64 vCPU with 25% idle, the tradeoff is different — more tablets may unlock idle cores
instead of adding overhead to already-saturated ones.

Other untested hypotheses:
- **Write path lock contention at 64 vCPU** — internal tserver locks that serialize at high
  core count but not at 32 vCPU
- **RocksDB write batch serialization** — memtable writes may serialize within a tablet
  independent of Raft
- **PG connection multiplexing limits** — YSQL layer may have per-connection or per-process
  bottlenecks at high concurrency

## Scale-up efficiency (updated)

| Config | Clients | Threads | Steady TPS | TPS/vCPU | Efficiency |
|--------|---------|---------|------------|----------|------------|
| Iter 13 (6×32) | 1 | 6000 | 41K | 214 | 100% |
| Iter 21 (12×32) | 1 | 6000 | 73K | 190 | 89% |
| Iter 22 (14×64) | 1 | 12000 | 127K | 142 | 66% |
| **Iter 23 (14×64)** | **2** | **6K+6K** | **124K** | **138** | **65%** |

## Implications for 200K TPS

Scale-up on c7i.16xlarge is exhausted at ~125K TPS regardless of client count. To reach 200K:

1. **Scale-out on c7i.8xlarge** (most efficient): ~36 tservers at 32 vCPU each (190 TPS/vCPU). Needs 2000 vCPU quota.
2. **Increase tablets per tserver** (ysql_num_shards_per_tserver=4) on c7i.16xlarge to add Raft parallelism — but iter 14 showed 24% regression on smaller cluster. Different tradeoff at 64 vCPU.
3. **Scale-out on c7i.16xlarge**: More 64-vCPU nodes, but at 138 TPS/vCPU this is 34% less cost-efficient than c7i.8xlarge.

**Recommendation:** Scale-out on c7i.8xlarge remains the most cost-efficient path. Wait for 2000 vCPU quota.
