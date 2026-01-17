# YugabyteDB Scalability Test Infrastructure

Test infrastructure for evaluating YugabyteDB scalability under high-volume CDC (Change Data Capture) streaming from simulated Oracle and DB2 sources.

## Architecture

```
┌────────────────────┐     ┌─────────────┐     ┌──────────────────┐
│  CDC Producer      │────▶│   Kafka     │────▶│   YugabyteDB     │
│  (Oracle/DB2 sim)  │     │  (Strimzi)  │     │   (YSQL)         │
└────────────────────┘     └─────────────┘     └──────────────────┘
                                  │
                           ┌──────▼──────┐
                           │  Prometheus │
                           └─────────────┘
```

**Components:**
- **CDC Producer** - Spring Boot app generating Debezium-format CDC events
- **Kafka (Strimzi)** - Message broker using KRaft mode (no ZooKeeper)
- **Kafka Connect** - JDBC sink connector to write to YugabyteDB
- **YugabyteDB** - Distributed PostgreSQL-compatible database
- **Prometheus** - Metrics collection

## Prerequisites

- Docker
- kubectl
- Minikube (for local testing) or AWS CLI (for cloud deployment)
- Helm 3.x
- Java 21+ (for local producer development)

## Quick Start (Minikube)

```bash
# 1. Setup minikube with Strimzi and YugabyteDB
./scripts/setup-minikube.sh

# 2. Deploy Kafka cluster, topics, and other components
make deploy ENV=minikube

# 3. Build and load the CDC producer image
make build-producer
make load-producer-minikube

# 4. Check status
make status

# 5. Run load test (default: 1000 events/sec)
make run-test EVENTS_PER_SECOND=1000
```

## Project Structure

```
.
├── k8s/
│   ├── base/                    # Base Kubernetes manifests
│   │   ├── strimzi/             # Kafka cluster & connect configs
│   │   ├── producer/            # CDC producer deployment
│   │   ├── prometheus/          # Monitoring
│   │   └── yugabytedb/          # YugabyteDB Helm values
│   └── overlays/
│       ├── minikube/            # Minikube-specific patches
│       └── aws/                 # AWS-specific patches
├── producers/                   # Java CDC producer application
│   ├── src/
│   └── Dockerfile
├── sink/                        # JDBC sink connector configs
├── scripts/                     # Setup and deployment scripts
└── Makefile                     # Build and deployment commands
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make setup-minikube` | Setup minikube with Strimzi and YugabyteDB |
| `make deploy` | Deploy all components |
| `make build-producer` | Build the CDC producer Docker image |
| `make load-producer-minikube` | Load producer image into minikube |
| `make run-test` | Run load test |
| `make status` | Show status of all components |
| `make logs` | Show CDC producer logs |
| `make logs-kafka` | Show Kafka broker logs |
| `make logs-connect` | Show Kafka Connect logs |
| `make ysql` | Connect to YugabyteDB YSQL shell |
| `make port-forward-prometheus` | Port forward Prometheus to localhost:9090 |
| `make clean` | Delete all resources |

## Configuration

### Producer Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `EVENTS_PER_SECOND` | 1000 | Target events per second |
| `THREADS` | 4 | Number of producer threads |
| `MODE` | both | Event mode: `oracle`, `db2`, or `both` |

### Kafka Topics

| Topic | Source | Description |
|-------|--------|-------------|
| `oracle-cdc-customers` | Oracle | Customer records |
| `oracle-cdc-orders` | Oracle | Order records |
| `db2-cdc-products` | DB2 | Product catalog |
| `db2-cdc-inventory` | DB2 | Inventory updates |

## CDC Event Format

Events are generated in Debezium envelope format:

```json
{
  "before": null,
  "after": {
    "id": 1,
    "name": "John Doe",
    "email": "john@example.com",
    "created_at": 1705123456789
  },
  "source": {
    "version": "2.4.0.Final",
    "connector": "oracle",
    "name": "oracle-source",
    "db": "ORCL",
    "schema": "TESTDB",
    "table": "CUSTOMERS"
  },
  "op": "c",
  "ts_ms": 1705123456789
}
```

## Deploying JDBC Sink Connectors

To enable data flow from Kafka to YugabyteDB:

```bash
kubectl --context minikube apply -f sink/jdbc-sink-connector.yaml
```

This creates sink connectors for all four topics, writing to corresponding tables in YugabyteDB.

## Monitoring

### Prometheus Metrics

Access Prometheus UI:
```bash
make port-forward-prometheus
# Open http://localhost:9090
```

Key metrics:
- `cdc.events.sent` - Total events sent to Kafka
- `cdc.events.errors` - Error count
- `cdc.events.latency` - Send latency histogram

### Checking Data in YugabyteDB

```bash
make ysql
# Then run SQL queries:
# SELECT COUNT(*) FROM customers;
# SELECT COUNT(*) FROM orders;
```

## Technology Stack

| Component | Version |
|-----------|---------|
| Kubernetes | 1.33+ |
| Strimzi | 0.49.1 |
| Apache Kafka | 4.1.1 |
| YugabyteDB | Latest |
| Kafka Connect JDBC | 10.7.4 |
| Java | 21 |
| Spring Boot | 3.2.1 |

## Troubleshooting

### Kafka Connect build fails
The Kafka Connect image is built with the JDBC connector and pushed to `ttl.sh` (ephemeral registry with 2h TTL). If the image expires, delete the KafkaConnect resource and reapply:

```bash
kubectl --context minikube delete kafkaconnect kafka-connect -n yugabyte-test
make deploy ENV=minikube
```

### Pod scheduling issues
Minikube has limited resources. Check node capacity:
```bash
kubectl --context minikube describe node minikube | grep -A 10 "Allocated resources"
```

### View component logs
```bash
make logs           # Producer logs
make logs-kafka     # Kafka broker logs
make logs-connect   # Kafka Connect logs
```
