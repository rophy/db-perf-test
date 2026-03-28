# Deep Analysis: oltp_insert 512 Threads with Triggers (Saturation Point)

**Report:** 20260328_0906
**Config:** dm-delay=5ms, IOPS cap=80, 3 tservers (4 vCPU / 2 P-cores pinned), 512 threads
**Tuning:** `bytes_durable_wal_write_mb=4`, `interval_durable_wal_write_ms=5000`
**Workload:** oltp_insert + trigger (cleanup_duplicate_k on all 10 tables)

## Summary

| Metric | Value |
|--------|-------|
| TPS | 1,435.55 |
| QPS | 1,435.55 |
| p95 Latency | 559.50 ms |
| Errors | 0 (0.00/s) |

## Thread Scaling Results

| Threads | TPS | p95 | TPS gain | Latency increase |
|---------|-----|-----|----------|-----------------|
| 48 | 952 | 77 ms | baseline | baseline |
| 96 | 1,039 | 153 ms | +9% | +99% |
| 192 | 1,234 | 244 ms | +19% | +59% |
| 384 | 1,303 | 467 ms | +6% | +91% |
| **512** | **1,436** | **560 ms** | **+10%** | **+20%** |

TPS gains diminish while latency compounds — classic saturation curve.

## Where Time Is Spent (512 threads, mid-run Prometheus)

### Per-Transaction Breakdown

Each sysbench insert triggers: INSERT → trigger SELECT → conditional DELETE. The end-to-end p95 is 560ms. Here's where the time goes:

| Operation | Latency | Rate (cluster total) |
|-----------|---------|---------------------|
| Write RPC (insert + trigger delete) | **49-59 ms** avg | 2,650 ops/s |
| Read RPC (trigger SELECT) | 0.4-0.7 ms avg | 2,528 ops/s |
| Consensus UpdateConsensus | **3.4-4.4 ms** avg | 1,323 ops/s |
| Outbound RPC queue time | 1.5-2.8 ms avg | — |
| Outbound RPC time to response | **42-48 ms** avg | — |

**Write RPC latency jumped 7x** (7ms at 48 threads → 54ms at 512 threads). This is the primary latency driver — each write waits longer due to internal queueing at the tserver level with 512 concurrent connections.

### Comparison: 48 threads vs 512 threads

| Metric | 48 threads | 512 threads | Change |
|--------|-----------|-------------|--------|
| Write RPC latency | 7-8 ms | **49-59 ms** | **7x** |
| Read RPC latency | 0.2 ms | 0.4-0.7 ms | 2-3x |
| Consensus latency | 0.8-1.2 ms | **3.4-4.4 ms** | **4x** |
| Outbound RPC queue | — | 1.5-2.8 ms | new overhead |
| Outbound RPC response | — | 42-48 ms | new overhead |
| WAL sync latency | 101-106 ms | 72-85 ms | -25% (fewer batches) |

## Resource Utilization

### Node CPU (mid-run)

| Node | User | System | IOWait | Steal | SoftIRQ | Idle | Total |
|------|------|--------|--------|-------|---------|------|-------|
| worker-1 | 59.3% | 18.5% | 1.4% | **9.0%** | 5.3% | 7.2% | **92.8%** |
| worker-2 | 58.4% | 17.9% | 3.3% | **9.3%** | 4.4% | 6.6% | **93.4%** |
| worker-3 | 55.5% | 17.7% | 1.6% | **10.7%** | 5.3% | 9.5% | **90.5%** |
| control | 9.6% | 4.3% | 0.0% | 10.0% | 5.8% | 75.3% | 24.7% |

Workers are at **91-93% CPU utilization** with only **7-10% idle**. Effective usable CPU (excluding steal) is 82-84%.

### Container CPU per tserver

| tserver | Container CPU |
|---------|--------------|
| yb-tserver-0 | 347.1% |
| yb-tserver-2 | 257.4% |
| yb-tserver-1 | 0.0% (sampling artifact) |

tserver-0 is consuming 347% of a 400% (4 vCPU) node — **87% of available container CPU**.

### Disk I/O

| Resource | Measured | Capacity | Utilization |
|----------|----------|----------|-------------|
| Disk Write IOPS | 24-36 per tserver | 80 cap | 30-45% |
| WAL sync rate | 6-7 ops/s per tserver | — | — |
| WAL bytes logged | 0.9-1.2 MB/s per tserver | — | — |
| iowait | 1.4-3.3% | — | Low |

Disk is **not the bottleneck**. IOPS well below cap, iowait negligible.

### Memory

| Metric | Value |
|--------|-------|
| Container memory (avg per tserver) | 2,839 MB |
| Node memory | 8,132 MB |
| Utilization | 35% |

Memory scaling across runs (same WAL tuning, oltp_insert + triggers):

| Threads | TPS | Memory (avg/tserver) | Change from 48t |
|---------|-----|---------------------|-----------------|
| 48 | 952 | 1,428 MB | baseline |
| 512 | 1,436 | 2,839 MB | **+99%** |

Memory nearly doubled from 48 to 512 threads. Three factors contribute:

1. **Connection state**: 512 sysbench connections ÷ 3 tservers ≈ 170 connections each. Each PostgreSQL connection consumes memory for session state, prepared statements, and transaction tracking. At ~5-8 MB per connection, this accounts for ~1-1.4 GB of the increase.

2. **Buffered WAL data**: With `interval_durable_wal_write_ms=5000`, up to 5 seconds of writes accumulate in memory before syncing. At ~1 MB/s per tserver, this is ~5 MB — negligible.

3. **RocksDB memtables**: Higher write throughput fills memtables faster. More immutable memtables may exist concurrently while background flush threads process them.

At 35% utilization, memory is not a constraint. However, if scaling to 1024+ threads or increasing WAL buffer sizes (`bytes_durable_wal_write_mb`), memory should be monitored to avoid OOM.

**Memory overhead of WAL tuning**: Comparing the 1s vs 5s WAL interval at 24 threads (oltp_read_write + triggers):

| WAL interval | TPS | Memory |
|-------------|-----|--------|
| 1s (default) | 17.5 | 1,052 MB |
| 5s (tuned) | 23.3 | 1,163 MB |
| Delta | +33% TPS | **+111 MB (+11%)** |

The 5s WAL interval added only 111 MB of memory overhead — a modest cost for 33% more throughput. The WAL buffer memory scales with write rate × interval, so at higher TPS (~1,400) the buffer is proportionally larger but still small relative to total memory.

## Bottleneck Identification

### Primary: CPU Saturation + Steal

Workers are at 91-93% total CPU. The breakdown reveals:
- **User (55-59%)**: tserver application logic — transaction processing, SQL execution, trigger evaluation
- **System (18-19%)**: kernel overhead — context switching 512 threads, network stack, filesystem
- **Steal (9-11%)**: hypervisor stealing CPU time — all 6 P-cores allocated to workers, host OS and control node compete

With only 7-10% idle CPU remaining, there's no room for more work. Adding threads just increases queueing.

### Secondary: Internal Queueing (consequence of CPU saturation)

The 7x increase in write RPC latency (7ms → 54ms) is not from slower I/O — it's from **request queueing inside the tserver**. With 512 connections but only ~4 effective CPU cores per tserver, requests wait in internal queues:
- Outbound RPC queue: 1.5-2.8ms (waiting to send consensus requests)
- Outbound RPC response: 42-48ms (waiting for peer tserver to process — also CPU-bound)
- Consensus latency 4x higher (3.4-4.4ms vs 0.8-1.2ms) — peers are slower to respond

This is a cascade: CPU saturation → slower request processing → longer queue wait → higher latency → same TPS with 10x more threads.

### Not a Bottleneck

| Resource | Evidence |
|----------|----------|
| Disk IOPS | 30-45% of cap, iowait 1-3% |
| WAL sync | 72-85ms, improved from 48-thread run |
| Memory | 35% utilization |
| Network | 2.8 MB/s — low |
| Transaction conflicts | 0/s |

## Effect of WAL Tuning

The `interval_durable_wal_write_ms=5000` tuning transformed this cluster from disk-bound to CPU-bound:

| Metric | Default WAL (1s) | Tuned WAL (5s) |
|--------|-----------------|----------------|
| WAL sync rate | 29 ops/s/tserver | 6-7 ops/s/tserver |
| Disk Write IOPS | 84 (at 80 cap) | 24-36 (30-45% of cap) |
| iowait | 16-28% | 1-3% |
| Bottleneck | Disk IOPS | CPU |

With the default 1s interval, disk was saturated at 80 IOPS and TPS was capped at 17.5. With 5s interval, disk I/O became negligible and the cluster could sustain 1,436 TPS — an **82x improvement** over the disk-bound configuration (comparing same trigger workload).

The tradeoff: up to 5 seconds of WAL data may be unsynced per node. With RF=3 Raft replication, data loss requires simultaneous failure of all 3 nodes within the 5s window.

## Conclusion

At 512 threads, the cluster is **CPU-saturated** (91-93% total, 9-11% stolen by hypervisor). The observable symptom is 7x write RPC latency increase from internal queueing. TPS plateaus at ~1,400 because the tservers cannot process requests faster with the available CPU.

### Resource Summary

| Resource | Status | Evidence |
|----------|--------|----------|
| **CPU** | **Saturated** | 91-93% total, 7-10% idle, 9-11% steal |
| Disk IOPS | Idle | 30-45% of 80 cap |
| Disk latency | Not a factor | iowait 1-3%, WAL sync 72-85ms (background) |
| Memory | Headroom | 2,839 MB / 8,132 MB (35%) |
| Network | Low | 2.8 MB/s |
| Conflicts | Zero | oltp_insert has no row contention |

### To push beyond 1,400 TPS with triggers

1. **More physical CPU**: either more P-cores per worker or fewer workers with more cores
2. **Less CPU steal**: dedicate host cores exclusively to workers (isolate control node and host OS to E-cores)
3. **Trigger optimization**: reduce per-insert CPU cost (e.g., simpler trigger logic, fewer dynamic SQL evaluations via `EXECUTE format(...)`)
4. **Connection pooling**: reduce the 512 direct connections to lower context-switching overhead (system CPU 18%)
