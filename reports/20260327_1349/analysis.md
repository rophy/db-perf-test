# Bottleneck Analysis: 2 vCPU Pinned Workers, Write-Heavy

**Report:** 20260327_1349
**Config:** dm-delay=1ms, IOPS cap=500, 3 tservers, 24 threads
**VM Spec:** Control: 2 shared vCPUs | Workers: 2 vCPUs each, pinned to 1 dedicated P-core (both HT threads)
**Workload:** oltp_read_write, write-heavy (2 point_selects, 20 index_updates, 20 non_index_updates, 10 rows/insert)

## Summary

| Metric | Value |
|--------|-------|
| TPS | 49.73 |
| QPS | 2,337.95 |
| p95 Latency | 623.33 ms |
| Avg Latency | 482.59 ms |
| Errors/s | 2.01 |

## Comparison: 4-vCPU (unpinned) vs 2-vCPU (pinned)

Both runs: same dm-delay=1ms, IOPS=500, write-heavy workload, 24 threads.

| Metric | 4 vCPU unpinned | 2 vCPU pinned | Change |
|--------|----------------|---------------|--------|
| TPS | 58.22 | 49.73 | -15% |
| QPS | 2,731.94 | 2,337.95 | -14% |
| p95 Latency | 549.52 ms | 623.33 ms | +13% |
| Node CPU avg | 62% | 80% | +29% |
| CPU steal | 6.2% | 4.5% avg (report), 7.1% mid-run | mixed |
| Disk Write IOPS | 75 avg | 97 avg | +29% |

## Bottleneck: CPU Saturation

### Evidence

#### 1. Worker node CPU is near saturation (80-95%)

Measured at mid-run via Prometheus `node_cpu`:

| Node | CPU total | CPU steal |
|------|-----------|-----------|
| ygdb-worker-1 | **87.2%** | 7.0% |
| ygdb-worker-2 | **84.4%** | 6.5% |
| ygdb-worker-3 | **94.8%** | 7.8% |

With only 2 logical CPUs (1 P-core) per worker, the tserver processes are consuming nearly all available CPU. Worker-3 at 94.8% is effectively saturated.

Report-period averages (includes ramp-up/down):

| Node | CPU total | User | System | IOWait | Steal | SoftIRQ |
|------|-----------|------|--------|--------|-------|---------|
| ygdb-worker-1 | 74.9% | — | — | — | — | — |
| ygdb-worker-2 | 85.5% | — | — | — | — | — |
| ygdb-worker-3 | 79.3% | — | — | — | — | — |
| **Avg** | **79.9%** | **33.8%** | **12.3%** | **3.1%** | **4.5%** | **7.0%** |

#### 2. WAL sync latency is 9-10 ms (similar to 4-vCPU run)

Measured at mid-run via Prometheus `log_sync_latency`:

| tserver | WAL sync avg | WAL sync rate |
|---------|-------------|---------------|
| yb-tserver-0 | 8.62 ms | 35.3 ops/s |
| yb-tserver-1 | 9.10 ms | 36.2 ops/s |
| yb-tserver-2 | 10.37 ms | 36.4 ops/s |

WAL sync latency is comparable to the 4-vCPU run (~10 ms). Disk I/O latency has not changed — the dm-delay is the same.

#### 3. Write RPC latency increased on tserver-0 (leader imbalance)

Measured at end of run via Prometheus `handler_latency`:

| tserver | Write RPC avg | Read RPC avg | Write rate |
|---------|--------------|-------------|------------|
| yb-tserver-0 | **5.23 ms** | 0.14 ms | 1,374.8 ops/s |
| yb-tserver-1 | 3.36 ms | 0.15 ms | 980.6 ops/s |
| yb-tserver-2 | 3.23 ms | 0.14 ms | 898.8 ops/s |

tserver-0 handles 42% of write ops and has 57% higher write latency (5.23 vs 3.3 ms). This suggests tablet leader imbalance — tserver-0 hosts more leaders, causing CPU contention on its 2-vCPU node.

#### 4. Consensus replication latency is slightly elevated

| tserver | UpdateConsensus avg |
|---------|-------------------|
| yb-tserver-0 | 0.57 ms |
| yb-tserver-1 | 0.32 ms |
| yb-tserver-2 | 0.34 ms |

tserver-0's consensus latency is ~70% higher than the others, consistent with CPU contention on that node.

#### 5. Disk IOPS is NOT the bottleneck

| tserver | Write IOPS (mid-run) | IOPS cap |
|---------|---------------------|----------|
| yb-tserver-0 | 97.4 | 500 |
| yb-tserver-1 | 95.7 | 500 |
| yb-tserver-2 | 98.4 | 500 |

Disk IOPS at ~97 per tserver, well below the 500 cap (19% utilization).

## Conclusion

The primary bottleneck is **CPU saturation on worker nodes**. With 2 vCPUs (1 P-core) per worker, the tservers consume 80-95% of available CPU during the write-heavy workload. This is a shift from the 4-vCPU configuration where the bottleneck was WAL sync latency — CPU now saturates before disk becomes the limiting factor.

Secondary factors:
- **Tablet leader imbalance**: tserver-0 handles disproportionate write load (42%), exacerbating CPU pressure on that node
- **WAL sync latency** (9-10 ms) remains a constant overhead but is no longer the primary constraint
- **CPU steal** (4.5-7.8%) indicates some host-level contention despite pinning — likely from the control node's shared vCPUs and host OS processes competing for the same P-cores' HT siblings
