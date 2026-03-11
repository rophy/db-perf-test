# Date Range Query Performance Test Report

**Date:** 2026-03-11

## Environment

### Host Machine

- **CPU:** Intel i7-13620H (13th Gen), 16 cores
- **RAM:** 62 GB
- **Virtualization:** minikube with KVM2 driver

### Kubernetes Cluster

4 minikube VMs, each with 4 vCPUs / 8 GB RAM:

| Node | Role | Workloads |
|------|------|-----------|
| minikube | master | YB masters x3, sysbench, prometheus |
| minikube-m02 | db | yb-tserver-2 |
| minikube-m03 | db | yb-tserver-1 |
| minikube-m04 | db | yb-tserver-0 |

### YugabyteDB Configuration

- 3 masters + 3 tservers, RF=3
- Storage: 2 x 10 Gi PVC per tserver
- YugabyteDB version: deployed via Helm subchart

## Table Definitions

### Table A: ASC Index (`date_range_test`)

Primary key on `id` (HASH), secondary index on `created_at` (ASC).

```sql
CREATE TABLE date_range_test (
    id SERIAL PRIMARY KEY,                -- lsm (id HASH)
    created_at TIMESTAMP NOT NULL,
    k INTEGER NOT NULL DEFAULT 0,
    c CHAR(120) NOT NULL DEFAULT '',
    pad CHAR(60) NOT NULL DEFAULT ''
);

CREATE INDEX idx_date_range_test_created_at
    ON date_range_test (created_at ASC);  -- lsm (created_at ASC)
```

**Tablet distribution (10M rows):**
- Table: 6 tablets (hash-partitioned by `id`), 2 per tserver
- Index: auto-split into 3 tablets (range-partitioned by `created_at`), 1 per tserver

### Table B: HASH Partitioned (`date_range_hash_test`)

Primary key on `created_at` (HASH) + `id` (ASC). No secondary index.

```sql
CREATE TABLE date_range_hash_test (
    created_at TIMESTAMP NOT NULL,
    id SERIAL,
    k INTEGER NOT NULL DEFAULT 0,
    c CHAR(120) NOT NULL DEFAULT '',
    pad CHAR(60) NOT NULL DEFAULT '',
    PRIMARY KEY (created_at HASH, id ASC)  -- lsm (created_at HASH, id ASC)
);
```

**Tablet distribution:** 6 tablets (hash-partitioned by `created_at`), 2 per tserver

## Data Generation

10 million rows per table, uniformly distributed across 1 year (2025-01-01 to 2025-12-31), ~27,400 rows per day.

```sql
INSERT INTO <table> (created_at, k, c, pad)
SELECT
    '2025-01-01'::timestamp + (random() * 365) * interval '1 day',
    (random() * 100000)::int,
    substr(repeat(md5(random()::text), 4), 1, 120),
    substr(md5(random()::text), 1, 60)
FROM generate_series(1, 500000);
-- Repeated 20 times for 10M total rows
```

## Query Plans

### Table A (ASC Index)

**SELECT \*:** Index Scan on `idx_date_range_test_created_at` — reads matching rows via sorted index, fetches full rows from table.

```
Index Scan using idx_date_range_test_created_at on date_range_test
  Index Cond: ((created_at >= ...) AND (created_at < ...))
```

**SELECT COUNT(\*):** Index Only Scan with Partial Aggregate — counts directly from index without fetching table rows.

```
Finalize Aggregate
  -> Index Only Scan using idx_date_range_test_created_at on date_range_test
       Index Cond: ((created_at >= ...) AND (created_at < ...))
       Partial Aggregate: true
```

### Table B (HASH Partitioned)

**SELECT \*:** Sequential Scan with Storage Filter — must scan all 10M rows across all tablets, filtering in storage layer.

```
Seq Scan on date_range_hash_test
  Storage Filter: ((created_at >= ...) AND (created_at < ...))
```

**SELECT COUNT(\*):** Sequential Scan with Partial Aggregate — same full scan, but counts are aggregated per-tablet then finalized.

```
Finalize Aggregate
  -> Seq Scan on date_range_hash_test
       Storage Filter: ((created_at >= ...) AND (created_at < ...))
       Partial Aggregate: true
```

## SQL Tested

```sql
-- SELECT *
SELECT * FROM <table>
WHERE created_at >= '2025-01-01'::timestamp + interval '<offset> days'
  AND created_at < '2025-01-01'::timestamp + interval '<offset + interval> days';

-- SELECT COUNT(*)
SELECT COUNT(*) FROM <table>
WHERE created_at >= '2025-01-01'::timestamp + interval '<offset> days'
  AND created_at < '2025-01-01'::timestamp + interval '<offset + interval> days';
```

Each query runs once (cold, no caching). The date offset is randomized per query.
Client-side latency is measured end-to-end via `kubectl exec` (includes ~100-150ms kubectl overhead).
SELECT * output is written to a temp file to avoid buffering results in memory.

## Results

### SELECT COUNT(*) — Client-side Latency

Measured via `kubectl exec` with ysqlsh and psql clients.

#### ysqlsh

| Interval | ~Rows | ASC (index scan) | HASH (full scan) |
|----------|-------|-------------------|-------------------|
| 1 day | ~27K | **169 ms** | 911 ms |
| 7 days | ~192K | **219 ms** | 875 ms |
| 30 days | ~822K | **355 ms** | 931 ms |
| 90 days | ~2.5M | **624 ms** | 911 ms |
| 180 days | ~4.9M | **900 ms** | 993 ms |

#### psql

| Interval | ~Rows | ASC (index scan) | HASH (full scan) |
|----------|-------|-------------------|-------------------|
| 1 day | ~27K | **202 ms** | 866 ms |
| 7 days | ~192K | **319 ms** | 903 ms |
| 30 days | ~822K | **451 ms** | 983 ms |
| 90 days | ~2.5M | **735 ms** | 919 ms |
| 180 days | ~4.9M | **968 ms** | 1,009 ms |

### SELECT * — Client-side Latency

Output piped to file to measure actual data transfer time.

#### ysqlsh

| Interval | ~Rows | ASC (index scan) | HASH (full scan) |
|----------|-------|-------------------|-------------------|
| 1 day | ~27K | **579 ms** | 1,244 ms |
| 7 days | ~192K | 2,518 ms | **1,664 ms** |
| 30 days | ~822K | 10,812 ms | **3,375 ms** |

#### psql

| Interval | ~Rows | ASC (index scan) | HASH (full scan) |
|----------|-------|-------------------|-------------------|
| 1 day | ~27K | **591 ms** | 1,440 ms |
| 7 days | ~192K | 2,676 ms | **1,705 ms** |
| 30 days | ~822K | 11,196 ms | **4,047 ms** |

### Server-side Latency (via `\timing`, 50-iteration average)

For reference, server-side timing from an earlier 50-iteration warm run:

#### SELECT COUNT(*)

| Interval | ~Rows | ASC | HASH |
|----------|-------|-----|------|
| 1 day | ~27K | **13.79 ms** | 986 ms |
| 7 days | ~192K | **55.52 ms** | 810 ms |
| 30 days | ~822K | **196 ms** | 879 ms |
| 90 days | ~2.5M | **473 ms** | 966 ms |
| 180 days | ~4.9M | **768 ms** | 1,083 ms |

## Analysis

### COUNT(*) Performance

- **ASC index scales linearly** with the number of matching rows. For small ranges (1 day), server-side latency is ~14ms.
- **HASH is flat at ~800-1000ms** regardless of interval — it always full-scans all 10M rows across all 6 tablets, with per-tablet partial aggregation.
- **ASC wins at every interval** for COUNT(*). Even scanning half the table (180 days, ~4.9M rows) is faster than HASH's fixed full-scan cost.
- COUNT(*) on ASC uses an **Index Only Scan** — no table row fetches needed.

### SELECT * Performance

- **ASC is faster for small ranges** (1 day) due to targeted index scan.
- **HASH is faster for large ranges** (7+ days) because it parallelizes the scan across 3 tservers, while ASC streams all matching rows from the index sequentially.
- **Crossover point** is around 7 days (~192K rows) where both take ~2.5 seconds.
- The ASC bottleneck for large SELECT * is single-node sequential streaming of result rows.

### Client Comparison

- **ysqlsh vs psql:** No meaningful performance difference. Both are PostgreSQL wire protocol clients; the bottleneck is server-side query execution and data transfer, not client parsing.

### Key Takeaway

For date range queries on YugabyteDB:
- Use an **ASC index** for range queries — it enables efficient index scans instead of full table scans.
- **COUNT(\*)** benefits enormously from ASC indexes (Index Only Scan with Partial Aggregate).
- **SELECT \*** on large ranges may benefit from HASH partitioning's cross-node parallelism, but this comes at the cost of full table scans for all queries.
- In most practical scenarios (filtering, pagination, aggregation), the ASC index is the better choice.
