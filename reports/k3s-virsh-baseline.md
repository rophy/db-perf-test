# k3s-virsh Baseline Performance Results

Date: 2026-03-25

## Host Machine

- Intel i7-13620H (13th Gen), 16 cores, 62 GB RAM
- Disk: NVMe SSD

## Cluster Setup

- 4 VMs on libvirt/KVM, Ubuntu 24.04, k3s v1.34.5
- 1 control node (role=master): YB masters, sysbench, prometheus
- 3 worker nodes (role=db): 1 tserver each, RF=3
- Disk: cache=none, io=native (no dm-delay, no throughput throttle)
- YugabyteDB 2.23.1, sysbench oltp_read_write
- 10 tables × 100K rows, 24 threads, 120s test, 30s warmup

## Results

### Test 1: 4 shared vCPUs per VM (no CPU pinning)

| VM | vCPUs | Pinned | Memory |
|---|---|---|---|
| ygdb-control | 4 | no | 8 GB |
| ygdb-worker-1/2/3 | 4 | no | 8 GB |

| Metric | Value |
|---|---|
| TPS | 42.06 |
| QPS | 1437.50 |
| 95th latency | 746.32 ms |
| Avg container CPU (per tserver) | 172.9% |
| Avg VM CPU (workers) | 72% |
| Steal time | 14.1% |
| I/O wait | 9.1% |
| Write IOPS | 278 |
| Errors | 56 (0.46/s) |

### Test 2: 2 dedicated vCPUs per VM (CPU pinning)

| VM | vCPUs | Pinned to | Memory |
|---|---|---|---|
| ygdb-control | 2 | host CPUs 0-1 | 8 GB |
| ygdb-worker-1 | 2 | host CPUs 2-3 | 8 GB |
| ygdb-worker-2 | 2 | host CPUs 4-5 | 8 GB |
| ygdb-worker-3 | 2 | host CPUs 6-7 | 8 GB |

| Metric | Value |
|---|---|
| TPS | 44.41 |
| QPS | 1517.75 |
| 95th latency | 657.93 ms |
| Avg container CPU (per tserver) | 129.9% |
| Avg VM CPU (workers) | 80% |
| Steal time | 6.6% |
| I/O wait | 3.5% |
| Write IOPS | 310 |
| Errors | 62 (0.51/s) |

### Comparison

| Metric | 4 shared | 2 dedicated | Delta |
|---|---|---|---|
| TPS | 42.06 | 44.41 | +5.6% |
| QPS | 1437.50 | 1517.75 | +5.6% |
| 95th latency | 746 ms | 658 ms | -12% (better) |
| Steal time | 14.1% | 6.6% | -53% |
| I/O wait | 9.1% | 3.5% | -62% |

### Test 3: 2 dedicated vCPUs, consistency re-run (no delay)

Same config as Test 2, fresh deploy to verify result reproducibility.

| Metric | Value |
|---|---|
| TPS | 47.16 |
| QPS | 1608.59 |
| 95th latency | 601.29 ms |
| Avg container CPU (per tserver) | 121.3% |
| Avg VM CPU (workers) | 80% |
| Steal time | 6.1% |
| I/O wait | 3.4% |
| Write IOPS | 289 |
| Errors | 51 (0.42/s) |

### Test 4: 2 dedicated vCPUs, 2ms dm-delay

Same config as Test 2, with 2ms per-I/O latency injected via dm-delay on tserver storage.

| Metric | Value |
|---|---|
| TPS | 33.97 |
| QPS | 1158.24 |
| 95th latency | 893.56 ms |
| Avg container CPU (per tserver) | 67.1% |
| Avg VM CPU (workers) | 82% |
| Steal time | 5.2% |
| I/O wait | 5.8% |
| System CPU | 25.4% |
| Write IOPS | 632 |
| Errors | 39 (0.32/s) |

### Test 5: 2 dedicated vCPUs, 4ms dm-delay

| Metric | Value |
|---|---|
| TPS | 30.90 |
| QPS | 1053.79 |
| 95th latency | 1050.76 ms |
| Avg container CPU (per tserver) | 69.1% |
| Avg VM CPU (workers) | 83% |
| Steal time | 4.8% |
| I/O wait | 4.6% |
| System CPU | 29.8% |
| Write IOPS | 541 |
| Errors | 37 (0.31/s) |

### Full Comparison (2 dedicated vCPUs)

| Metric | No delay (run 1) | No delay (run 2) | 2ms delay | 4ms delay |
|---|---|---|---|---|
| TPS | 44.41 | 47.16 | 33.97 | 30.90 |
| QPS | 1517.75 | 1608.59 | 1158.24 | 1053.79 |
| 95th latency | 658 ms | 601 ms | 894 ms | 1051 ms |
| Container CPU | 129.9% | 121.3% | 67.1% | 69.1% |
| System CPU | 14.6% | 14.6% | 25.4% | 29.8% |
| I/O wait | 3.5% | 3.4% | 5.8% | 4.6% |
| Write IOPS | 310 | 289 | 632 | 541 |

Run-to-run variance (no delay): ~6% TPS, consistent infrastructure metrics.

### Observations

- 2 dedicated vCPUs outperformed 4 shared vCPUs despite having half the cores.
- Main factor: reduced steal time (14% → 7%) from CPU pinning eliminates scheduling jitter.
- Tservers use ~130% of 200% available CPU — moderately loaded, not fully saturated.
- Both no-delay configs are CPU-bound (low I/O wait, write IOPS similar).
- Run-to-run variance is ~6% for no-delay tests — acceptable for this environment.
- **2ms disk delay dropped TPS by ~26%** (avg 45.8 → 34.0), shifting the bottleneck from CPU to I/O.
- **4ms delay dropped TPS by ~33%** (avg 45.8 → 30.9), further degradation but diminishing impact per ms.
- Container CPU dropped from ~126% to ~68% with any delay — tservers become I/O-bound immediately.
- System CPU rose from 14.6% to 30% — kernel doing more I/O scheduling work under delay.
- Write IOPS increased with delay (300 → 540-630) — likely more frequent smaller flushes under I/O pressure.
