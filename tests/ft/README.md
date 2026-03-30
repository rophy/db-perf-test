# Fault Tolerance Tests

Tests for verifying YugabyteDB data consistency and availability under node failures.

## Test Scenarios

- **Single master down** — verify cluster remains operational
- **Single tserver down** — verify reads/writes continue, data consistent after recovery
- **Two tservers down** — verify behavior when quorum is lost (RF=3)

## Approach

1. Write known data with recorded transaction IDs (HLC timestamps)
2. Kill target node(s)
3. Verify all committed transactions are readable and consistent
4. Recover node(s)
5. Verify recovered node catches up and data matches

## Prerequisites

- k3s-virsh cluster running with YugabyteDB deployed (`make deploy-k3s-virsh`)
- kubectl context: `k3s-ygdb`
