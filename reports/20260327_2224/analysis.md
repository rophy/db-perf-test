# Bottleneck Analysis: Trigger + Stored Procedure Overhead

**Report:** 20260327_2224
**Config:** dm-delay=5ms, IOPS cap=80, 3 tservers (2 vCPU pinned), 24 threads
**Workload:** oltp_read_write, write-heavy + trigger (point select + conditional delete per write)

## Summary

| Metric | Value |
|--------|-------|
| TPS | 17.50 |
| QPS | 836.04 |
| p95 Latency | 2,279 ms |
| Avg Latency | 1,371 ms |
| Errors/s | 1.43 |

## Comparison: Without Trigger vs With Trigger

Same cluster spec: dm-delay=5ms, IOPS=80, 24 threads, write-heavy.

| Metric | Without Trigger | With Trigger | Change |
|--------|----------------|--------------|--------|
| TPS | 34.78 | **17.50** | **-50%** |
| QPS | 1,625 | 836 | -49% |
| p95 Latency | 1,150 ms | **2,279 ms** | **+98%** |
| WAL sync latency | ~40 ms | **~145 ms** | **+3.6x** |
| WAL sync rate | ~36 ops/s | ~29 ops/s | -19% |
| Disk Write IOPS | ~66 | **~84** | **+27%** |
| Write RPC latency | 4-5 ms | **9-10 ms** | **+2x** |
| Write RPC rate | ~3,250 total | **~1,029 total** | -68% |
| Node CPU | 91-97% | **95-98%** | still saturated |
| iowait | 8-13% | **17-28%** | **+2x** |

## Bottleneck: Compounded I/O Amplification from Trigger

The trigger doubles the write I/O per transaction, pushing the already IOPS-constrained system deeper into saturation.

### Evidence

#### 1. WAL sync latency exploded to 145ms (was 40ms)

| tserver | WAL sync avg | WAL sync rate |
|---------|-------------|---------------|
| yb-tserver-0 | **145.45 ms** | 28.4 ops/s |
| yb-tserver-1 | **148.07 ms** | 29.9 ops/s |
| yb-tserver-2 | **143.30 ms** | 27.4 ops/s |

WAL sync latency jumped 3.6x despite the dm-delay still being 5ms. This indicates **I/O queueing** at the IOPS cap — writes are waiting in a queue because the 80 IOPS cap can't drain them fast enough.

#### 2. Disk IOPS is at the cap (80-85)

| tserver | Write IOPS (mid-run) | IOPS cap |
|---------|---------------------|----------|
| yb-tserver-0 | 81.9 | 80 |
| yb-tserver-1 | **85.3** | 80 |
| yb-tserver-2 | 84.9 | 80 |

IOPS is at or slightly above the cap (burstiness). Without the trigger, IOPS was 66 — now it's saturating the 80 cap.

#### 3. iowait doubled (17-28%)

| Node | iowait without trigger | iowait with trigger |
|------|----------------------|---------------------|
| ygdb-worker-1 | ~8% | **16.8%** |
| ygdb-worker-2 | ~13% | **27.9%** |
| ygdb-worker-3 | ~13% | **27.3%** |

Threads are spending significantly more time blocked on disk I/O.

#### 4. Write RPC latency doubled (9-10ms vs 4-5ms)

| tserver | Write RPC avg |
|---------|--------------|
| yb-tserver-0 | 8.97 ms |
| yb-tserver-1 | 10.13 ms |
| yb-tserver-2 | 9.16 ms |

Each write RPC takes 2x longer because the trigger adds a point select + delete within the same transaction, and the delete requires its own WAL sync.

#### 5. CPU remains saturated but shifted to iowait

| Node | CPU total | CPU user | iowait |
|------|-----------|----------|--------|
| ygdb-worker-1 | 98.1% | — | 16.8% |
| ygdb-worker-2 | 95.2% | — | 27.9% |
| ygdb-worker-3 | 96.0% | — | 27.3% |

Report-period averages: user 25.0%, system 9.5%, **iowait 16.5%**, steal 3.2%, softirq 5.4%

CPU is still near 100%, but the composition shifted — iowait grew from 8% to 16.5%, meaning more CPU time is spent waiting on disk rather than doing useful work.

#### 6. Transaction conflicts remain low

| tserver | Conflicts/s |
|---------|------------|
| yb-tserver-0 | 0.3/s |
| yb-tserver-1 | 0.5/s |
| yb-tserver-2 | 0.2/s |

Conflicts are not a significant factor (total ~1/s across cluster).

## Mechanism

Each sysbench write transaction (41 writes) now triggers the `cleanup_duplicate_k` function on every INSERT and UPDATE:

1. **Sysbench INSERT/UPDATE** → triggers function
2. **Trigger: point select** on index `k` → read I/O (fast, 0.15ms)
3. **Trigger: conditional DELETE** by PK → write I/O (WAL sync + Raft replication)

The trigger's DELETE adds ~1 extra write per sysbench write operation. With 41 writes per transaction, the trigger adds up to 41 additional deletes, effectively **doubling the write I/O**. On an 80-IOPS-capped system:

- Without trigger: 66 IOPS (82% of cap) → some queueing
- With trigger: 84 IOPS (105% of cap) → severe queueing → WAL sync 145ms

The WAL sync latency (145ms) is the clearest signal: with 5ms dm-delay and no queueing, sync should be ~40ms (as measured without trigger). The extra 105ms is pure **I/O queue wait time** from IOPS saturation.

## Trigger Function

```sql
CREATE OR REPLACE FUNCTION cleanup_duplicate_k()
RETURNS TRIGGER AS $$
DECLARE
    old_id INTEGER;
BEGIN
    -- Point select: find an older row with the same k value
    EXECUTE format('SELECT id FROM %I WHERE k = $1 AND id < $2 LIMIT 1', TG_TABLE_NAME)
    INTO old_id
    USING NEW.k, NEW.id;

    -- Conditional delete: remove the older duplicate
    IF old_id IS NOT NULL THEN
        EXECUTE format('DELETE FROM %I WHERE id = $1', TG_TABLE_NAME)
        USING old_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Applied to: sbtest1-10, fires on INSERT and UPDATE.
