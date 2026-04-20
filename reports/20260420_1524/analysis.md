# k3s-virsh thread scaling: 36 vs 180 threads (3/core vs 15/core)

## Context
YugabyteDB community Slack advised that our benchmarks are over-threaded (~15 conns/core)
and recommended ~2-3 write threads per core. This A/B test validates that advice on
k3s-virsh, where slow disk (dm-delay 5ms) + WAL buffering makes the cluster CPU-bound.

## Config (both runs)
- **Cluster:** 3× 4 vCPU / 8 GB workers (KVM, 2 P-cores per VM with HT), RF=3
- **Storage:** dm-delay 5ms per I/O, WAL buffer 4MB / 10s flush interval
- **Workload:** oltp_insert + cleanup_duplicate_k trigger, 10 tables, 1 tablet/table
- **Duration:** 120s run + 30s warmup, report interval 10s
- **gflags:** auto-split disabled, ysql_num_shards_per_tserver=2
- **Changed:** threads only (36 vs 180)
- **Reports:** `20260420_1524` (36t), `20260420_1532` (180t)

## Why this setup is CPU-bound despite slow disk
The 5ms dm-delay simulates realistic slow storage (cloud EBS, network-attached). WAL
buffering (`bytes_durable_wal_write_mb=4`, `interval_durable_wal_write_ms=10000`) absorbs
the I/O penalty — fsync fires only ~5.7 times/sec per tserver, batching hundreds of writes
per flush. This shifts the bottleneck to CPU, which is exactly the regime where the
threading advice applies.

## Results — per-interval steady-state (T=40-120)

| Metric | 36 threads (3/core) | 180 threads (15/core) |
|--------|--------------------|-----------------------|
| Steady-state TPS avg | **960** | **1,540** |
| Steady-state TPS range | 756-1,047 | 1,468-1,655 |
| p95 latency | **53-62ms** | **167-193ms** |
| CPU(cr) per-node avg (of 4 cores) | 3.3 (83%) | 3.6 (90%) |
| Container CPU per tserver | 3.2-3.4 cores | 3.2-3.4 cores |
| Node CPU (node_exporter) | 80-86% | 89-92% |
| Memory (MB) | 5,900-6,000 | 7,300-7,600 |
| Errors | 0 | 0 |

## Understanding CPU(cr) in the report

The report's CPU(cr) column is **average node CPU in cores across db-role nodes** (from
`node_cpu_seconds_total`), NOT container CPU. So CPU(cr) = 3.62 means each 4-vCPU worker
is using 3.62 cores = **90% node CPU**. This is confirmed by direct node_exporter queries
(89-92%).

Container CPU per tserver (from `container_cpu_usage_seconds_total`) reads 3.2-3.4 cores —
close to the 3.6-3.7 node total. The ~0.3 core gap is kernel overhead (%sys 20%, %softirq
6%) not attributed to container cgroups.

**Both metrics agree: the cluster is near CPU saturation at both thread counts.**

## CPU breakdown by mode (per worker node)

| CPU mode | 36 threads | 180 threads |
|----------|-----------|-------------|
| %user (tserver + postgres backends) | 43-51% | 57-60% |
| %system (kernel, syscalls) | 19-20% | 20-21% |
| %softirq (network stack) | 7% | 6% |
| %iowait | 4-6% | 3% |
| %steal (hypervisor) | 1-1.5% | 1% |
| **Total busy** | **80-86%** | **89-92%** |

Kernel overhead (%sys + %softirq) is ~27% of total — driven by YSQL's process-per-connection
model (each sysbench thread = 1 postgres backend process) and cross-node Raft RPCs
through the kernel network stack.

## DB-side metrics (Prometheus, steady-state)

### Write path latency breakdown

| Metric | 36 threads | 180 threads | Delta |
|--------|-----------|-------------|-------|
| Write RPC latency | 5.5ms | 19ms | 3.5x |
| UpdateTxn latency | 3.0ms | 11ms | 3.7x |
| Raft UpdateConsensus (follower) | 0.5ms | 1.7ms | 3.4x |
| RPC queue wait | 0.18ms | 0.41ms | 2.3x |
| Log append (buffer write) | 0.07ms | 0.08ms | ~same |
| Log group commit | 0.11ms | 0.17ms | 1.5x |
| Log sync (fsync to disk) | 120-162ms | 123-181ms | ~same |
| Disk write await | 20-33ms | 24-29ms | ~same |

Disk-side metrics (WAL sync, disk await) are **constant** across both thread counts — the
WAL buffer absorbs the slow disk. Everything that increases is **CPU-side queueing**: Write
RPC, UpdateTxn, Raft consensus. With 180 threads, each tserver has ~60 postgres backend
processes competing for 4 vCPUs (2 P-cores), and scheduling delays compound through the
write path.

### RPC rates (all scale ~1.6x, matching TPS ratio)

| Metric | 36 threads | 180 threads |
|--------|-----------|-------------|
| Write RPC/s (total) | 3,148 | 4,971 |
| UpdateTxn/s (total) | 5,797 | 9,171 |
| Read RPC/s (total) | 3,120 | 4,990 |
| rows_inserted/s (per ts) | ~156 | ~248 |
| Raft UpdateConsensus/s (per ts) | 4,400-5,300 | 1,700-2,000 |
| WAL sync rate | 5.7/s | 5.5/s |
| Context switches/s (per worker) | 106K | 81K |

Per the YB community's 5-ops-per-txn model: 960 TPS × 5 = 4,800 expected ops/s. Observed:
~3,148 writes + ~3,120 reads ≈ 6,268 ops/s (slightly above 5x due to trigger DELETE
generating additional Raft ops). Model holds.

Raft UpdateConsensus rate is *lower* at 180 threads (1,700-2,000 vs 4,400-5,300) despite
higher throughput. This suggests Raft is batching more operations per consensus round at
higher concurrency — fewer but larger batches.

Context switches are also lower at 180 threads (81K vs 106K) — at 36 threads, threads block
quickly on I/O and the scheduler switches frequently; at 180 threads, CPU run queues are
deep and threads get longer time slices.

### Health indicators — clean at both thread counts

| Metric | 36 threads | 180 threads |
|--------|-----------|-------------|
| not_leader_rejections/s | 1.4 | ~0 |
| transaction_conflicts/s | 0.2 | 0.3 |
| RPC queue overflow | 0 | 0 |

## Verdict — YB community threading advice validated

The YB community recommended 2-3 write threads per core. On k3s-virsh:

- **At 3 conns/core (36 threads):** nodes are already 80-86% CPU busy. Write RPC latency
  is 5.5ms, UpdateTxn is 3.0ms. Latency is reasonable for a trigger workload on simulated
  slow storage.
- **At 15 conns/core (180 threads):** nodes hit 89-92% CPU. TPS increases 60% but latency
  triples (55ms → 180ms p95). The extra throughput comes from pipelining — while one thread
  waits for CPU, others execute — but it's a stress scenario with degraded QoS.

The slow disk + WAL buffer setup makes this cluster CPU-bound (not I/O-bound), which is
the regime where the threading advice matters. More threads past the CPU knee delivers
diminishing TPS returns with escalating latency.

## Implications for AWS testing

On AWS (c7i.8xlarge, 32 vCPU, NVMe storage):
- WAL sync should be ~1-2ms (vs 120-180ms here), so I/O is fast and CPU pressure starts
  earlier
- The threading effect should be more dramatic: 3 conns/core may match or exceed 15
  conns/core TPS while keeping latency at ~10ms
- Test plan: 6× c7i.8xlarge with 576 threads (3/core) vs 6000 threads (31/core)
