# Fault Tolerance Tests

Tests for verifying YugabyteDB data consistency and availability under node failures.

## Quick Start

```bash
# Single tserver pod kill (graceful)
./tests/ft/ft-run.sh --scenario 1-tserver-down --target yb-tserver-0

# Single tserver VM crash (hard power off)
./tests/ft/ft-run.sh --scenario 1-tserver-down --target yb-tserver-1 --failure-mode vm-destroy

# Single master down
./tests/ft/ft-run.sh --scenario 1-master-down --target yb-master-0

# Two tservers down (quorum loss)
./tests/ft/ft-run.sh --scenario 2-tserver-down --target "yb-tserver-0 yb-tserver-1"
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--scenario` | (required) | Test name (used in report directory) |
| `--target` | (required) | Pod name(s) to kill (space-separated for multiple) |
| `--failure-mode` | `pod-delete` | `pod-delete` (graceful) or `vm-destroy` (hard) |
| `--duration` | `30` | Failure duration in seconds |
| `--baseline` | `10` | Baseline write duration before failure |
| `--recovery-wait` | `30` | Wait time after recovery |
| `--interval` | `100` | Insert interval in milliseconds |

## Test Flow

1. **Pre-flight** — check cluster health
2. **Start writer** — continuous inserts with journal logging
3. **Baseline** — write for N seconds to establish normal operation
4. **Inject failure** — kill target pod(s) or VM(s)
5. **Write during failure** — continue inserting (some will fail)
6. **Recover** — restart killed pod(s) or VM(s)
7. **Stabilize** — wait for recovery and catch-up
8. **Stop writer** — end the write workload
9. **Verify** — compare journal against database

## Verification

The verifier checks:
- **Missing committed rows** — rows acknowledged as OK in the journal but absent from DB → **FAIL**
- **Corrupted payloads** — row exists but md5 checksum doesn't match → **FAIL**
- **Extra rows** — rows in DB that weren't acknowledged (in-flight at failure time) → acceptable

## Components

| Script | Purpose |
|--------|---------|
| `ft-run.sh` | Test orchestrator |
| `ft-writer.sh` | Continuous insert writer with journal |
| `ft-inject.sh` | Failure injection (kill/recover) |
| `ft-verify.sh` | Data consistency verification |

## Reports

Test results are saved to `tests/ft/reports/<scenario>_<timestamp>/`:
- `test-config.txt` — test parameters and timing
- `writer-journal.csv` — every insert attempt and result
- `verify-result.txt` — verification summary

## Prerequisites

- k3s-virsh cluster running with YugabyteDB deployed
- kubectl context: `k3s-virsh` (or set `KUBE_CONTEXT`)
