# Analysis: 20260414_2205 vs 20260328_0906

Reproduction of the 20260328_0906 benchmark on the same k3s-virsh lab, with the co-tenant `oracle-rac-vm` shut down to remove CPU steal. Everything else — workload, WAL tuning, disk throttles, vCPU count, P-core pinning — is identical to the original.

## Configuration

| | 20260328_0906 | 20260414_2205 |
|---|---|---|
| Workload | oltp_insert + `cleanup_duplicate_k` trigger on sbtest1..10 | same |
| Threads | 512 | 512 |
| Duration | 120s (warmup 30s) | same |
| Tables × rows | 10 × 100,000 | same |
| WAL tuning | `bytes_durable_wal_write_mb=4`, `interval_durable_wal_write_ms=5000`, `durable_wal_write=false` | same |
| dm-delay | 5 ms | 5 ms |
| IOPS cap | 80 | 80 |
| Worker vCPU | 4 | 4 |
| Worker memory | 8 GB | 8 GB |
| P-core pinning | 2 P-cores per worker | 2 P-cores per worker (1:1 vcpu→thread, CPUs 0–3 / 4–7 / 8–11; see `VM_PINNING.txt`) |
| Co-tenant VM | `oracle-rac-vm` running | `oracle-rac-vm` **shut down** |

Host: Intel i7-13620H (6 P-cores + 4 E-cores, 62 GB RAM).

## Result

| Metric | 20260328_0906 | 20260414_2205 | Delta |
|---|---|---|---|
| TPS | 1,436 | **2,005.17** | **+40%** |
| p95 latency | 560 ms | 427 ms | −24% |
| avg latency (from sysbench) | n/a in this summary | see `sysbench_output.txt` | — |
| Errors | 0 | 0 | — |
| Worker CPU (total) | 91–93% | 80–81% | −12 pts |
| user | 38.8% | 39.4% | — |
| system | 12.7% | 16.2% | +3.5 |
| iowait | 0.9% | 4.0% | +3.1 |
| **steal** | **8.6%** | **1.7%** | **−6.9** |
| softirq | 4.4% | 4.8% | — |
| Cluster disk write IOPS | 23 | 50 | +27 |
| Tserver container CPU (sum) | 273.7% | 121.1% | lower |
| Memory (sum) | 2,839 MB | 1,986 MB | lower |

## Interpretation

The only environmental change between runs is the removal of `oracle-rac-vm` as an unpinned co-tenant on the host. That change produces:

1. **Steal drops from 8.6% → 1.7%.** The host can now keep the pinned worker vCPUs on their assigned P-cores without preemption.
2. **Disk IOPS utilization rises from 23 → 50** (of the 80 cap). With the CPUs no longer being stolen, the cluster actually generates more WAL fsync traffic per second, but still operates well under the disk cap.
3. **TPS rises 40% and p95 drops 24%.** The workload was CPU-starved in the original run, not disk-bound.

The implication for the earlier 20260328_0906 analysis: its framing of the IOPS cap as the binding constraint is only partially right. With steal removed, the same disk cap supports 2,005 TPS — within 2.6% of the unconstrained-disk result (2,059 TPS measured separately on this lab). Above ~2,000 TPS the 80-IOPS cap does begin to bind, but below that the limiter is CPU availability.

## What Buffered WAL Buys Here (unchanged conclusion)

At 2,005 TPS with 50 cluster write IOPS, each fsync batches ~40 client commits. A per-commit fsync policy would require ~2,800 IOPS for this throughput, which is ~35× the available disk budget. The `bytes_durable_wal_write_mb=4 / interval_durable_wal_write_ms=5000` tuning is what makes this configuration viable at all. This matches the 20260328_0906 finding; the new run just shows the ceiling is higher than previously measured.

## What Can Still Skew Results

- **iowait climbed from 0.9% → 4.0%.** At higher throughput the disk cap is starting to matter. A follow-up at IOPS cap = 40 (or equivalent) would tell us how much headroom remains.
- **Container CPU is lower in the new run (121% vs 273%).** That is counterintuitive given higher TPS, and suggests the Prometheus sampling window or metric source differs between reports; worth verifying before treating it as a real change.
- P-core pinning exactness depends on libvirt domain XML; both runs used "2 P-cores per worker" but the exact CPU IDs may have differed across host reboots. Material only if the kernel's scheduler class differs, which it shouldn't here.
