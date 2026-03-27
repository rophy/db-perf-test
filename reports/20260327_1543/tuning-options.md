# YugabyteDB Write Tuning Options for Slow Disk

**Context:** 2 vCPU pinned workers, dm-delay=5ms, IOPS=80, write-heavy workload
**Current bottleneck:** Disk I/O — iowait 18.1%, WAL fsync ~40ms, TPS 34.8

## Option 1: `log_group_commit_interval_ms`

Increase the WAL group commit window to batch more writes per fsync.

**What it does:** The Raft WAL collects writes for up to N ms before issuing a single fsync. More writes per fsync = fewer total fsyncs = less IOPS pressure.

**Default:** 0 (no artificial delay — fsync as soon as a batch is ready)

**Side effects:**
- Adds up to N ms latency to every write, even at low load. A single write that could complete in 5ms now waits up to N ms for a batch that may never fill.
- At high load (many concurrent writes), the batch fills quickly and the interval rarely matters — the benefit is real.
- At low load, this is pure latency penalty with no throughput gain.

**Tradeoff:** Better throughput under load, worse tail latency at low load.

**How to apply:**
```yaml
# values-k3s-virsh.yaml
yugabyte:
  gflags:
    tserver:
      log_group_commit_interval_ms: 20
```

**What to measure:**
- `log_sync_latency` — should decrease (fewer, larger syncs)
- `log_group_commit_latency` — may increase (waiting longer per batch)
- `log_sync rate` — should decrease (fewer syncs/s)
- TPS — should increase if IOPS-bound

---

## Option 2: `rocksdb_write_buffer_size`

Increase the RocksDB memtable size to buffer more data in memory before flushing to disk.

**What it does:** Each tablet's RocksDB instance accumulates writes in an in-memory memtable. When it reaches this size, it flushes to an SST file on disk. Larger buffer = fewer flushes = fewer disk writes.

**Default:** ~64MB

**Side effects:**
- Higher memory usage **per tablet**. With N tablets per tserver, total memory = buffer_size x N x max_write_buffer_number.
- Current setup: ~2 shards/tserver x 10 tables = ~20 tablets. At 256MB x 20 = 5GB per tserver — fits in 8GB but leaves little headroom.
- If sized too large, tservers OOM and get killed.
- Larger memtables mean more data loss on crash (not yet flushed to disk).

**Tradeoff:** Fewer disk flushes, but higher memory usage and OOM risk.

**How to apply:**
```yaml
yugabyte:
  gflags:
    tserver:
      rocksdb_write_buffer_size: 134217728  # 128MB (conservative for 8GB nodes)
```

**What to measure:**
- Tserver memory usage — watch for OOM
- `rocksdb_flush_write_bytes` — should show larger, less frequent flushes
- Disk write IOPS — should decrease

---

## Option 3: `rocksdb_max_write_buffer_number`

Allow more concurrent memtables in memory while one is being flushed.

**What it does:** When a memtable fills and starts flushing to disk, new writes go to a fresh memtable. This setting controls how many memtables can exist simultaneously. More = better write burst absorption.

**Default:** 2

**Side effects:**
- Multiplies memory usage from Option 2. With buffer_size=128MB and max=4, each tablet could use up to 512MB.
- More L0 SST files accumulate before compaction, increasing **read amplification** — reads must check more files.
- Delays compaction, which can cause write stalls later when L0 file count hits `level0_slowdown_writes_trigger`.

**Tradeoff:** Absorbs write bursts better, but increases memory usage and may degrade read latency.

**How to apply:**
```yaml
yugabyte:
  gflags:
    tserver:
      rocksdb_max_write_buffer_number: 4
```

**What to measure:**
- Memory usage per tserver
- Read latency — watch for degradation
- `rocksdb_num_immutable_mem_table` — shows queued memtables waiting to flush

---

## Recommended Test Order

1. **Option 1 first** — safest, no memory risk, directly reduces fsync count
2. **Option 2 second** — moderate risk, size conservatively for 8GB nodes
3. **Option 3 last** — compounds memory risk from Option 2

## Current Cluster Spec

| Component | Value |
|-----------|-------|
| Workers | 3 x 2 vCPU (1 P-core pinned) |
| Memory | 8 GB per worker |
| dm-delay | 5ms per I/O |
| IOPS cap | 80 |
| Tablets/tserver | ~20 (2 shards x 10 tables) |
| WAL sync latency | ~40ms |
| Disk write IOPS | ~66 (hitting 80 cap) |
