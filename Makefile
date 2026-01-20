.PHONY: help deploy clean status ysql
.PHONY: sysbench-prepare sysbench-run sysbench-cleanup sysbench-shell sysbench-logs
.PHONY: report

KUBE_CONTEXT ?= minikube
NAMESPACE ?= yugabyte-test
RELEASE_NAME ?= yb-bench
CHART_DIR := charts/yb-benchmark

# Database connection
PG_HOST ?= yb-tserver-service
PG_PORT ?= 5433
PG_USER ?= yugabyte
PG_PASS ?= yugabyte
PG_DB ?= yugabyte

# Sysbench parameters (per YugabyteDB docs: https://docs.yugabyte.com/stable/benchmark/sysbench-ysql/)
SYSBENCH_TABLES ?= 20
SYSBENCH_TABLE_SIZE ?= 5000000
SYSBENCH_THREADS ?= 60
SYSBENCH_TIME ?= 1800
SYSBENCH_WARMUP ?= 300
SYSBENCH_WORKLOAD ?= oltp_read_write

# Common sysbench flags
SYSBENCH_DB_OPTS := \
	--db-driver=pgsql \
	--pgsql-host=$(PG_HOST) \
	--pgsql-port=$(PG_PORT) \
	--pgsql-user=$(PG_USER) \
	--pgsql-password=$(PG_PASS) \
	--pgsql-db=$(PG_DB) \
	--tables=$(SYSBENCH_TABLES) \
	--table_size=$(SYSBENCH_TABLE_SIZE)

# YugabyteDB-specific prepare flags
SYSBENCH_PREPARE_OPTS := $(SYSBENCH_DB_OPTS) \
	--range_key_partitioning=false \
	--serial_cache_size=1000 \
	--create_secondary=true

# YugabyteDB-specific run flags (CRITICAL: range_selects=false prevents 100x slowdown)
SYSBENCH_RUN_OPTS := $(SYSBENCH_DB_OPTS) \
	--range_key_partitioning=false \
	--serial_cache_size=1000 \
	--create_secondary=true \
	--threads=$(SYSBENCH_THREADS) \
	--time=$(SYSBENCH_TIME) \
	--warmup-time=$(SYSBENCH_WARMUP) \
	--report-interval=10 \
	--range_selects=false \
	--point_selects=10 \
	--index_updates=10 \
	--non_index_updates=10 \
	--num_rows_in_insert=10 \
	--thread-init-timeout=90

KUBECTL := kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE)
SYSBENCH_POD := deployment/$(RELEASE_NAME)-sysbench

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Deployment
deploy: ## Deploy full stack (YugabyteDB + benchmarks + prometheus)
	@helm repo add yugabytedb https://charts.yugabyte.com 2>/dev/null || true
	@helm repo update yugabytedb
	@helm dependency build $(CHART_DIR)
	@helm upgrade --install $(RELEASE_NAME) $(CHART_DIR) \
		--kube-context $(KUBE_CONTEXT) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--set fullnameOverride=$(RELEASE_NAME) \
		--wait --timeout 15m

deploy-benchmarks: ## Deploy benchmarks only (use existing YugabyteDB)
	@helm upgrade --install $(RELEASE_NAME) $(CHART_DIR) \
		--kube-context $(KUBE_CONTEXT) \
		--namespace $(NAMESPACE) \
		--set yugabyte.enabled=false \
		--set fullnameOverride=$(RELEASE_NAME) \
		--wait --timeout 5m

# Sysbench operations - runs sysbench DIRECTLY with YugabyteDB-optimized flags
sysbench-prepare: ## Prepare sysbench tables (20 tables x 5M rows per YB docs)
	$(KUBECTL) exec $(SYSBENCH_POD) -- \
		sysbench $(SYSBENCH_WORKLOAD) $(SYSBENCH_PREPARE_OPTS) prepare

sysbench-run: ## Run sysbench benchmark (1800s per YB docs)
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) \
		SYSBENCH_WORKLOAD=$(SYSBENCH_WORKLOAD) \
		SYSBENCH_RUN_OPTS="$(SYSBENCH_RUN_OPTS)" \
		./scripts/sysbench-run-with-timestamps.sh

sysbench-cleanup: ## Cleanup sysbench tables
	$(KUBECTL) exec $(SYSBENCH_POD) -- \
		sysbench $(SYSBENCH_WORKLOAD) $(SYSBENCH_DB_OPTS) cleanup

sysbench-shell: ## Open shell in sysbench container
	$(KUBECTL) exec -it $(SYSBENCH_POD) -- /bin/bash

sysbench-logs: ## Show sysbench container logs
	$(KUBECTL) logs -f $(SYSBENCH_POD)

# Report generation
report: ## Generate performance report from last benchmark run
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) ./scripts/report-generator/report.sh

# Utilities
status: ## Show status of all components
	@echo "=== Pods ==="
	@$(KUBECTL) get pods -o wide
	@echo ""
	@echo "=== Services ==="
	@$(KUBECTL) get svc

ysql: ## Connect to YugabyteDB YSQL shell
	$(KUBECTL) exec -it yb-tserver-0 -- /home/yugabyte/bin/ysqlsh -h yb-tserver-service

port-forward-prometheus: ## Port forward Prometheus to localhost:9090
	$(KUBECTL) port-forward svc/$(RELEASE_NAME)-prometheus 9090:9090

# Cleanup
clean: ## Delete all resources
	@echo "Uninstalling $(RELEASE_NAME)..."
	@helm --kube-context $(KUBE_CONTEXT) uninstall $(RELEASE_NAME) -n $(NAMESPACE) 2>/dev/null || true
	@echo "Deleting PVCs..."
	@$(KUBECTL) delete pvc -l app=yb-tserver 2>/dev/null || true
	@$(KUBECTL) delete pvc -l app=yb-master 2>/dev/null || true
	@echo "Deleting namespace..."
	@kubectl --context $(KUBE_CONTEXT) delete namespace $(NAMESPACE) --ignore-not-found
