# Analysis: oltp_insert with Triggers

**Report:** 20260328_0842
**Config:** dm-delay=5ms, IOPS cap=80, 3 tservers (4 vCPU / 2 P-cores pinned), 48 threads
**Tuning:** `bytes_durable_wal_write_mb=4`, `interval_durable_wal_write_ms=5000`
**Workload:** oltp_insert + trigger (cleanup_duplicate_k on all 10 tables)

## Summary

| Metric | Value |
|--------|-------|
| TPS | 952.44 |
| QPS | 952.44 |
| p95 Latency | 77.19 ms |
| Errors | 0 (0.00/s) |
| Error % | 0% |

## Trigger Impact on oltp_insert

| Metric | No triggers | With triggers | Change |
|--------|------------|---------------|--------|
| TPS | 1,836 | **952** | **-48%** |
| Errors | 0 | 0 | — |
| p95 | 37.6 ms | **77.2 ms** | **+2x** |
| Container CPU | 178% | **226%** | +27% |
| Node CPU avg | 73-85% | **79-85%** | similar |
| Write RPC rate (total) | 2,307 ops/s | **1,906 ops/s** | -17% |
| Read RPC rate (total) | 0 ops/s | **1,859 ops/s** | new |
| Disk Write IOPS | 31-33 | 24-35 | similar |
| WAL sync latency | 64-91 ms | **101-106 ms** | +50% |

## Trigger Overhead Breakdown

Each insert now triggers `cleanup_duplicate_k()` which adds:
1. **Point SELECT** on index `k` → measured at 0.20-0.24 ms per read RPC
2. **Conditional DELETE** by PK → adds a write RPC when a matching row exists

Evidence from Prometheus (mid-run):

### Write RPCs

| tserver | Latency | Rate |
|---------|---------|------|
| yb-tserver-0 | 7.04 ms | 601 ops/s |
| yb-tserver-1 | 8.22 ms | 672 ops/s |
| yb-tserver-2 | 7.36 ms | 633 ops/s |
| **Total** | | **1,906 ops/s** |

### Read RPCs (from trigger's SELECT)

| tserver | Latency | Rate |
|---------|---------|------|
| yb-tserver-0 | 0.20 ms | 663 ops/s |
| yb-tserver-1 | 0.24 ms | 672 ops/s |
| yb-tserver-2 | 0.23 ms | 525 ops/s |
| **Total** | | **1,860 ops/s** |

Read rate (~1,860/s) closely matches TPS (952/s) — roughly 2 read RPCs per insert (the sysbench insert + trigger's SELECT may span multiple tablets).

### WAL Sync

| tserver | Latency | Rate |
|---------|---------|------|
| yb-tserver-0 | 100.69 ms | 7.0/s |
| yb-tserver-1 | 105.83 ms | 6.6/s |
| yb-tserver-2 | 102.02 ms | 6.4/s |

WAL sync latency increased 50% vs no-trigger (64ms → 103ms) due to larger WAL batches from the additional delete operations.

### Disk IOPS

| tserver | Write IOPS | IOPS cap |
|---------|-----------|----------|
| yb-tserver-0 | 34.5 | 80 |
| yb-tserver-1 | 23.8 | 80 |
| yb-tserver-2 | 26.6 | 80 |

Well below cap — IOPS is not a constraint.

### Node CPU Breakdown (mid-run)

| Node | User | System | IOWait | Steal | SoftIRQ | Total |
|------|------|--------|--------|-------|---------|-------|
| worker-1 | 48.7% | 16.7% | 4.7% | 8.6% | 6.3% | ~85% |
| worker-2 | 44.8% | 16.2% | 3.9% | 8.1% | 6.2% | ~79% |
| worker-3 | 43.9% | 16.0% | 4.1% | 6.7% | 5.9% | ~77% |

## Bottleneck: Per-Transaction Latency (Trigger Overhead)

No resource is saturated (CPU 77-85%, IOPS 30-43%, memory 16%). The bottleneck is **per-transaction latency**:

- Without trigger: ~7ms write RPC → 37ms end-to-end (pipelining across tablets)
- With trigger: ~7ms write RPC + 0.2ms read RPC + conditional delete RPC → 77ms end-to-end

The trigger doubles the work per transaction (1 extra SELECT + up to 1 DELETE), which doubles the latency. Since TPS = threads / latency, doubling latency halves TPS.

## Key Achievement: Zero Errors

Unlike `oltp_read_write` which had 5-13% error rates from row contention, `oltp_insert` produces zero conflicts because:
- Each insert creates a new row with a unique auto-increment ID
- The trigger's SELECT by `k` is a read (no write conflict)
- The trigger's DELETE targets a specific old row by PK — low collision probability with random `k` values across 100K+ rows

This makes oltp_insert + triggers a clean workload for YugabyteDB tuning without contention noise.
