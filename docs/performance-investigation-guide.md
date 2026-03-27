# YugabyteDB Performance Investigation Guide

A practical guide for identifying performance bottlenecks in YugabyteDB, based on measured results from the k3s-virsh performance tuning lab.

## Performance Tuning Lab Architecture

### Infrastructure

The lab uses libvirt/virsh-managed VMs with k3s for full control over infrastructure resources:

```
Host Machine (Intel i7-13620H, 16 cores, 62 GB RAM, NVMe SSD)
  │
  ├── ygdb-control VM (2 vCPU, 8 GB) — k3s server, YB masters, sysbench, prometheus
  ├── ygdb-worker-1 VM (2 vCPU, 8 GB) — 1 tserver
  ├── ygdb-worker-2 VM (2 vCPU, 8 GB) — 1 tserver
  └── ygdb-worker-3 VM (2 vCPU, 8 GB) — 1 tserver
```

- **CPU pinning**: each VM gets dedicated host CPUs (no steal time)
- **Raw disk format**: avoids qcow2 I/O amplification (see Design Decisions)
- **cache=none, io=native**: QEMU does direct I/O, no host page cache

### I/O Simulation Methods

Two methods for constraining disk I/O, applied at different layers:

| Method | Layer | What it does | Simulates |
|---|---|---|---|
| **dm-delay** | Host kernel (device-mapper) | Adds constant latency per I/O | Slow media (HDD, aging SSD, network storage) |
| **blkdeviotune** | QEMU hypervisor | Caps total IOPS | Provisioned IOPS (cloud EBS gp3, SAN) |

Both can be combined. Neither adds VM CPU overhead.

**dm-delay setup**: VM's raw disk image sits on a dm-delay backed ext4 filesystem on the host. Created via privileged Docker container (no sudo needed). All VM I/O traverses the delay.

```
Host: raw file → losetup → dm-delay (read+write) → ext4 → VM disk image
VM sees: single /dev/vda with consistent per-I/O latency
```

**blkdeviotune setup**: applied live via `virsh blkdeviotune <vm> vda --total-iops-sec N`.

### Measured I/O Characteristics (fio, raw format)

| Metric | No throttle | dm-delay 1ms | IOPS 200 |
|---|---|---|---|
| 4k random write IOPS (qd=32) | 189,110 | 19,110 | 193 |
| 4k random read IOPS (qd=32) | 212,725 | 20,000 | 6,754 |
| 4k random write IOPS (qd=1) | 30,632 | 999 | 199 |
| Write latency (qd=1) | 0.03 ms | **1.00 ms** | 5.01 ms |
| Write latency (qd=32) | 0.17 ms | 1.67 ms | **165.8 ms** |

dm-delay at iodepth=1 produces exactly 999 IOPS / 1.00ms — confirming 1:1 latency mapping with raw format.

## Design Decisions

### Raw disk format (not qcow2)

qcow2 adds a copy-on-write metadata layer that amplifies I/O: a single guest write triggers multiple host I/Os for data + metadata updates. Measured impact:

| Metric | qcow2 + 1ms delay | raw + 1ms delay |
|---|---|---|
| Write latency | **9.07 ms** (9x amplification) | **1.28 ms** (1.3x) |
| Read latency | 1.18 ms | 0.74 ms |

**Raw format is mandatory for accurate I/O simulation.** The tradeoff is 20GB per VM disk (vs thin-provisioned qcow2), which is acceptable on the host's 914GB disk.

### Host-level dm-delay (not in-VM)

dm-delay inside the VM consumes significant CPU in the VM's kernel:

| Metric | In-VM dm-delay | Host dm-delay |
|---|---|---|
| TPS (4ms delay, 48 threads) | 34.3 | **53.8** (+57%) |
| System CPU (VM) | **48.5%** (dm-delay kernel thread) | 22.5% |
| dm-delay process in VM | **63.6% CPU** | none |

The `dm-delay` kernel thread inside the VM consumed 63% of a CPU core, leaving less for YugabyteDB. Host-level dm-delay has zero VM CPU overhead.

### dm-delay read+write syntax

dm-delay has two forms:
- 5-arg: `0 $SECTORS delay $DEV $OFFSET $READ_DELAY` — **reads only**
- 8-arg: `0 $SECTORS delay $DEV $OFFSET $READ_DELAY $DEV $OFFSET $WRITE_DELAY` — **both**

Always use the 8-arg form. The 5-arg form silently ignores writes, producing incorrect benchmarks.

### YugabyteDB version matters

YugabyteDB 2025.2 has dramatically better WAL batching than 2.23.1:

| Metric | 2.23.1 (200 IOPS) | 2025.2 (200 IOPS) |
|---|---|---|
| TPS | 20.5 | ~80 |
| Actual write IOPS per tserver | ~200 (hitting cap) | ~4 (aggressive batching) |

The 2025.2 version batches WAL writes so aggressively that 200 IOPS barely registers as a constraint. This is an important finding: **database software version can have more performance impact than infrastructure tuning**.

## Key Diagnostic Tools

### 1. Tserver Prometheus Metrics (primary tool)

Each tserver exposes metrics on port 9000 at `/prometheus-metrics`. These are the most reliable source for bottleneck identification.

**WAL (Write-Ahead Log) metrics:**
```promql
# WAL fsync latency — time to sync WAL to disk (per tserver)
sum(rate(log_sync_latency_sum[1m])) by (instance)
  / sum(rate(log_sync_latency_count[1m])) by (instance)

# WAL group commit latency — batched append+sync
sum(rate(log_group_commit_latency_sum[1m])) by (instance)
  / sum(rate(log_group_commit_latency_count[1m])) by (instance)
```

**RPC latency metrics:**
```promql
# Write RPC latency (end-to-end write path)
sum(rate(handler_latency_yb_tserver_TabletServerService_Write_sum[1m])) by (instance)
  / sum(rate(handler_latency_yb_tserver_TabletServerService_Write_count[1m])) by (instance)

# Read RPC latency
sum(rate(handler_latency_yb_tserver_TabletServerService_Read_sum[1m])) by (instance)
  / sum(rate(handler_latency_yb_tserver_TabletServerService_Read_count[1m])) by (instance)

# Raft consensus replication latency
sum(rate(handler_latency_yb_consensus_ConsensusService_UpdateConsensus_sum[1m])) by (instance)
  / sum(rate(handler_latency_yb_consensus_ConsensusService_UpdateConsensus_count[1m])) by (instance)
```

**Throughput metrics:**
```promql
# Write operations per second per tserver
sum(rate(handler_latency_yb_tserver_TabletServerService_Write_count[1m])) by (instance)
```

### 2. Container/VM Metrics

```promql
# Container CPU usage per tserver (percentage of 1 core)
sum(rate(container_cpu_usage_seconds_total{container="yb-tserver"}[1m])) by (pod) * 100

# Node-level disk write IOPS
rate(node_disk_writes_completed_total[1m])
```

### 3. Tserver Web UI

- `/rpcz` — in-flight RPCs with elapsed time (real-time snapshot of what's slow)
- `/tablets` — tablet leaders and their distribution across tservers
- `/operations` — in-flight tablet operations
- `/varz` — runtime flags including `fs_data_dirs` and `fs_wal_dirs`

### 4. In-VM tools

- `iostat -dx vda 5` — real-time disk IOPS, latency, utilization inside the VM
- `fio` — synthetic I/O benchmarks to verify disk constraints are working
- `top` — check for unexpected CPU consumers (e.g., dm-delay kernel thread)

### 5. pg_stat_activity (limited usefulness)

```sql
SELECT state, wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE state != 'idle'
GROUP BY state, wait_event_type, wait_event
ORDER BY count(*) DESC;
```

**Limitation:** YugabyteDB replaces PostgreSQL's buffer manager with DocDB/RocksDB, so most queries show as `active` with no `wait_event_type` regardless of whether the bottleneck is CPU, disk, or Raft consensus. This tool is mainly useful for detecting lock waits, not I/O or CPU bottlenecks.

## Bottleneck Identification

### Quick Decision Tree

```
Is container CPU near the vCPU limit (e.g., ~190% on 2 vCPUs)?
  YES → CPU-bound (see below)
  NO  → Check WAL fsync latency
        Is log_sync_latency > 10ms?
          YES → Disk I/O bound (see below)
          NO  → Check Write RPC latency
                Is Write RPC latency high but WAL fsync low?
                  YES → Network or Raft consensus issue
                  NO  → Check thread count and lock contention
```

### CPU Bottleneck

**Symptoms (measured):**

| Metric | Normal (24 threads) | CPU-bound (72 threads) |
|---|---|---|
| Container CPU | 126% | 168% (near 200% limit) |
| VM CPU | 80% | 91-96% |
| TPS | 47.5 | 47.8 (flat despite 3x threads) |
| Write RPC latency | 6-8 ms | 20-30 ms (CPU queuing) |
| WAL fsync | 3.5-4.6 ms | 3.8-5.4 ms (unchanged) |
| 95th latency | 612 ms | 1771 ms (3x worse) |
| Errors/sec | 0.33 | 1.64 (5x more timeouts) |

**How to identify:**
1. Container CPU approaches the vCPU limit (200% on 2 vCPUs)
2. TPS plateaus — adding more threads doesn't increase throughput
3. Write RPC latency increases but WAL fsync stays constant
4. VM-level CPU is >90%
5. Latency and errors increase proportionally with thread count

**Key indicator:** WAL fsync latency is LOW but Write RPC latency is HIGH. The gap is CPU queuing time.

### Disk Latency Bottleneck

**Symptoms (measured with 4ms dm-delay on host, raw format):**

| Metric | No delay | 4ms dm-delay |
|---|---|---|
| Container CPU | 126% | LOW (waiting on disk) |
| TPS | 47.5 | decreased |
| WAL fsync | 3.5-4.6 ms | HIGH |
| Write RPC | 6-8 ms | increased |
| Read RPC | 0.24-0.34 ms | barely affected (block cache) |
| Raft consensus | 0.5-1.2 ms | increased |

**How to identify:**
1. WAL fsync latency is HIGH (>10ms)
2. Container CPU is LOW despite available capacity
3. I/O wait elevated in VM CPU breakdown
4. Read RPCs largely unaffected (served from block cache)
5. TPS drops even with low thread counts

**Key indicator:** Container CPU is LOW but WAL fsync is HIGH.

### Disk IOPS Bottleneck

**Symptoms (measured with 200 IOPS cap via blkdeviotune):**

| Metric | No limit | 200 IOPS cap |
|---|---|---|
| TPS | 47.5 | 20.5 (-57%) |
| WAL fsync | 3.5-4.6 ms | 178-202 ms (queuing) |
| Read RPC | 0.24-0.34 ms | 0.9-1.6 ms (affected!) |
| Actual write IOPS | ~300 | ~200 (hitting cap) |
| 95th latency | 612 ms | 2199 ms |
| TPS variance | stable | bursty (16-23 per interval) |

**How to identify:**
1. WAL fsync latency is VERY HIGH (>100ms) with high variance
2. Both reads AND writes are slow (shared IOPS budget)
3. Actual disk IOPS from `iostat` or node_exporter match the provisioned limit
4. TPS is highly variable (bursty — queues drain then refill)
5. 99th latency extremely high (queuing tail)

**Key difference from latency bottleneck:** IOPS cap affects reads too (shared budget). dm-delay mainly affects writes since reads hit block cache. IOPS bottleneck produces bursty, unpredictable latency vs dm-delay's constant latency.

### Asymmetric / Single Slow Node

**Symptoms (measured with 1 of 3 nodes at 4ms dm-delay):**

| Metric | Slow tserver-0 | Normal tserver-1 | Normal tserver-2 |
|---|---|---|---|
| WAL fsync | 32.0 ms | 3.2 ms | 3.2 ms |
| Write RPC | 16.2 ms | 4.3 ms | 4.2 ms |
| Raft consensus | 6.3 ms | 0.5 ms | 0.6 ms |
| Read RPC | 0.59 ms | 0.21 ms | 0.23 ms |

Overall TPS: 37.4 (vs 47.5 baseline = **-21% from one slow node**)

**How to identify:**
1. WAL fsync or Write RPC latency differs significantly across tservers
2. One tserver has metrics 5-10x worse than others
3. Thread fairness stddev is high (uneven query times)
4. TPS drop is larger than expected (~21% for 1/3 slow, not ~0%)

**Why one slow node affects the whole cluster:**
- The slow node is a **tablet leader** for ~1/3 of tablets
- As leader, it must sync its LOCAL WAL before responding — followers can't help
- Raft majority-ack doesn't help when the leader itself is slow
- All queries hitting those tablets experience the slow path

**How to observe in real-time:**
```promql
# Compare WAL fsync across tservers — outlier = slow node
sum(rate(log_sync_latency_sum[30s])) by (instance)
  / sum(rate(log_sync_latency_count[30s])) by (instance)

# Compare Write RPC latency — confirms user-facing impact
sum(rate(handler_latency_yb_tserver_TabletServerService_Write_sum[30s])) by (instance)
  / sum(rate(handler_latency_yb_tserver_TabletServerService_Write_count[30s])) by (instance)

# Write ops/sec per tserver — should be equal (not a routing issue)
sum(rate(handler_latency_yb_tserver_TabletServerService_Write_count[30s])) by (instance)
```

## Investigation Workflow

### Step 1: Establish baseline metrics

Before investigating, capture these baseline metrics under normal load:

```
Container CPU per tserver    → expected range for your hardware
WAL fsync latency            → depends on disk (NVMe: <5ms, SSD: 5-15ms, HDD: >15ms)
Write RPC latency            → typically 2-3x WAL fsync (includes Raft)
Read RPC latency             → typically <1ms (block cache hits)
iostat w_await / r_await     → raw disk latency inside VM
```

### Step 2: Compare against baseline

When performance degrades, compare current metrics against baseline:

| Changed metric | Unchanged metric | Likely bottleneck |
|---|---|---|
| WAL fsync UP | Container CPU DOWN | Disk latency |
| WAL fsync UP, reads also slow | Container CPU DOWN | Disk IOPS cap |
| Write RPC UP | WAL fsync SAME | CPU saturation |
| One tserver different | Others normal | Single node issue |
| All metrics UP | VM steal time UP | Host CPU contention |

### Step 3: Drill down

- **Disk issue confirmed** → run `iostat -dx vda 5` inside the VM. Check `w_await` (write latency) and `%util` (saturation). Compare with `fio` baseline.
- **CPU issue confirmed** → check VM steal time, check if CPU limits/requests are too low, check `top` for unexpected processes.
- **Single node issue** → check that specific node's disk health, network connectivity, check if it's running extra workloads. Consider moving tablet leaders away with `yb-admin`.
- **Raft consensus slow** → check network latency between nodes with `ping`. Check if follower nodes have disk issues (they need to sync WAL too for UpdateConsensus).

## Reference: Measured Baselines

All measured on k3s-virsh lab with YugabyteDB 2.23.1: 3 tservers, 2 dedicated vCPUs each, 8 GB RAM, RF=3, 24 sysbench threads (oltp_read_write, 10 tables × 100K rows).

| Scenario | TPS | WAL fsync | Write RPC | Container CPU |
|---|---|---|---|---|
| No bottleneck | 47.5 | 3.5-4.6 ms | 6-8 ms | 126% |
| CPU-bound (72 threads) | 47.8 | 3.8-5.4 ms | 20-30 ms | 168% |
| 2ms disk delay (in-VM) | 34.0 | ~32 ms | ~13 ms | 67% |
| 4ms disk delay (in-VM) | 30.9 | ~32 ms | ~13 ms | 69% |
| 4ms disk delay (host) | 53.8 | ~32 ms | ~13 ms | — |
| 200 IOPS cap | 20.5 | ~200 ms | ~31 ms | — |
| 1 slow node (4ms) | 37.4 | 32/3/3 ms | 16/4/4 ms | — |

Note: In-VM dm-delay results include 63% CPU overhead from the dm-delay kernel thread. Host dm-delay results are more accurate for real-world I/O-bound scenarios.
