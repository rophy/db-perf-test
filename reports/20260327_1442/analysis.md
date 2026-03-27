# Bottleneck Analysis: dm-delay=5ms, 2 vCPU Pinned Workers, Write-Heavy

**Report:** 20260327_1442
**Config:** dm-delay=5ms, IOPS cap=500, 3 tservers, 24 threads
**VM Spec:** Control: 2 shared vCPUs | Workers: 2 vCPUs each, pinned to 1 dedicated P-core
**Workload:** oltp_read_write, write-heavy (2 point_selects, 20 index_updates, 20 non_index_updates, 10 rows/insert)

## Summary

| Metric | Value |
|--------|-------|
| TPS | 50.63 |
| QPS | 2,372.98 |
| p95 Latency | 601.29 ms |
| Avg Latency | 474.23 ms |
| Errors/s | 1.89 |

## Comparison: dm-delay 1ms vs 5ms (same cluster spec)

| Metric | 1ms delay | 5ms delay | Change |
|--------|-----------|-----------|--------|
| TPS | 49.73 | 50.63 | +2% (noise) |
| QPS | 2,338 | 2,373 | +1% (noise) |
| p95 Latency | 623 ms | 601 ms | -4% (noise) |
| WAL sync avg | 9-10 ms | **40 ms** | **+4x** |
| Node CPU avg | 80-95% | **91-97%** | higher |
| iowait | 3.1% | **8.4%** | **+2.7x** |
| Disk Write IOPS | ~97 | ~97 | same |
| Write RPC avg | 3.2-5.2 ms | 4.0-5.0 ms | similar |

## Key Finding: TPS unchanged despite 4x WAL sync latency increase

Increasing dm-delay from 1ms to 5ms caused WAL sync latency to jump from ~10ms to ~40ms, yet TPS barely changed (49.7 → 50.6). This confirms **CPU is the bottleneck, not disk latency**.

### Evidence

#### 1. CPU is saturated (91-97%)

Measured at mid-run via Prometheus:

| Node | CPU total | iowait | steal |
|------|-----------|--------|-------|
| ygdb-worker-1 | **97.0%** | 5.9% | — |
| ygdb-worker-2 | **94.9%** | 8.2% | — |
| ygdb-worker-3 | **91.1%** | 12.8% | — |

Report-period averages: user 33.8%, system 12.6%, iowait 8.4%, steal 4.8%, softirq 7.2%

#### 2. WAL sync latency increased 4x but had no throughput impact

| tserver | WAL sync (1ms delay) | WAL sync (5ms delay) |
|---------|---------------------|---------------------|
| yb-tserver-0 | 8.62 ms | **39.65 ms** |
| yb-tserver-1 | 9.10 ms | **39.64 ms** |
| yb-tserver-2 | 10.37 ms | **39.87 ms** |

The WAL sync is 4x slower, but because CPU is already the bottleneck, the tserver threads can't generate enough write traffic to be limited by the slower disk. The iowait increased (3.1% → 8.4%) showing threads do wait on I/O, but total CPU (including iowait) is at saturation.

#### 3. Disk IOPS unchanged (~97 per tserver)

Write IOPS is the same as the 1ms run — the workload generates the same amount of disk I/O regardless of latency. At 97 IOPS vs 500 cap, disk throughput is not the constraint.

## Conclusion

With 2 vCPUs per worker, **CPU is the sole bottleneck**. The dm-delay increase from 1ms to 5ms had no measurable effect on TPS because the CPU saturates before disk latency becomes limiting. To observe disk latency as a bottleneck, the cluster would need more CPU headroom (e.g., 4 vCPUs per worker, as in the earlier 4-vCPU configuration where WAL sync was the identified bottleneck).
