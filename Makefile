.PHONY: help deploy clean status ysql
.PHONY: sysbench-prepare sysbench-run sysbench-cleanup sysbench-shell sysbench-logs sysbench-trigger
.PHONY: report vendor
.PHONY: range-query-test
.PHONY: cdc-deploy cdc-test cdc-status cdc-clean
.PHONY: setup-k3s-virsh teardown-k3s-virsh setup-slow-disk setup-slow-throughput adjust-disk-delay

# Environment and component selection
ENV ?= k3s-virsh
COMPONENT ?= all

NAMESPACE ?= yugabyte-test

# Map ENV to kube context
KUBE_CONTEXT_aws := kube-sandbox
KUBE_CONTEXT_minikube := minikube
KUBE_CONTEXT_k3s-virsh := k3s-virsh
KUBE_CONTEXT := $(KUBE_CONTEXT_$(ENV))

# Two independent Helm releases
YB_RELEASE := yugabyte
YB_CHART_DIR := charts/yugabyte
BENCH_RELEASE := yb-bench
BENCH_CHART_DIR := charts/yb-benchmark

# Backward compat for scripts that use RELEASE_NAME
RELEASE_NAME := $(BENCH_RELEASE)

# Slow disk simulation parameters
DISK_DELAY_MS ?= 0
DISK_BW_MBPS ?= 0
DISK_IOPS ?= 0

KUBECTL := kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE)
SYSBENCH_POD := $(BENCH_RELEASE)-sysbench-0

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Deployment (ENV=k3s-virsh|aws|minikube  COMPONENT=all|yb|bench)
deploy: ## Deploy components (ENV= COMPONENT=all|yb|bench)
ifeq ($(COMPONENT),all)
	$(MAKE) _deploy-yb
	$(MAKE) _deploy-bench
else ifeq ($(COMPONENT),yb)
	$(MAKE) _deploy-yb
else ifeq ($(COMPONENT),bench)
	$(MAKE) _deploy-bench
else
	$(error Unknown COMPONENT=$(COMPONENT). Use: all, yb, bench)
endif

_deploy-yb:
	@helm upgrade --install $(YB_RELEASE) $(YB_CHART_DIR) \
		--kube-context $(KUBE_CONTEXT) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		-f $(YB_CHART_DIR)/values-$(ENV).yaml \
		--wait --timeout 15m

_deploy-bench:
	@helm upgrade --install $(BENCH_RELEASE) $(BENCH_CHART_DIR) \
		--kube-context $(KUBE_CONTEXT) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--set fullnameOverride=$(BENCH_RELEASE) \
		-f $(BENCH_CHART_DIR)/values-$(ENV).yaml \
		--wait --timeout 5m

# Sysbench operations - uses scripts from ConfigMap (parameters in values.yaml)
sysbench-prepare: ## Prepare sysbench tables
	$(KUBECTL) exec $(SYSBENCH_POD) -- /scripts/sysbench-prepare.sh

sysbench-run: ## Run sysbench benchmark
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) \
		./scripts/sysbench-run-with-timestamps.sh

sysbench-trigger: ## Install cleanup_duplicate_k trigger on all sbtest tables
	@echo "Installing trigger on all sbtest tables..."
	@$(KUBECTL) cp scripts/trigger-setup.sql yb-tserver-0:/tmp/trigger-setup.sql -c yb-tserver
	@$(KUBECTL) exec yb-tserver-0 -c yb-tserver -- \
		ysqlsh -h yb-tserver-service -U yugabyte -d yugabyte -f /tmp/trigger-setup.sql

sysbench-cleanup: ## Cleanup sysbench tables
	$(KUBECTL) exec $(SYSBENCH_POD) -- /scripts/sysbench-cleanup.sh

sysbench-shell: ## Open shell in sysbench container
	$(KUBECTL) exec -it $(SYSBENCH_POD) -- /bin/bash

sysbench-logs: ## Show sysbench container logs
	$(KUBECTL) logs -f $(SYSBENCH_POD)

VENDOR_DIR := reports/vendor
VENDOR_FILES := \
	$(VENDOR_DIR)/chart.umd.js \
	$(VENDOR_DIR)/chartjs-adapter-date-fns.bundle.min.js \
	$(VENDOR_DIR)/chartjs-plugin-zoom.min.js \
	$(VENDOR_DIR)/hammer.min.js \
	$(VENDOR_DIR)/chartjs-plugin-annotation.min.js

vendor: $(VENDOR_FILES) ## Install JS vendor libs for reports

$(VENDOR_FILES): package.json
	npm install --ignore-scripts
	mkdir -p $(VENDOR_DIR)
	cp node_modules/chart.js/dist/chart.umd.js $(VENDOR_DIR)/
	cp node_modules/chartjs-adapter-date-fns/dist/chartjs-adapter-date-fns.bundle.min.js $(VENDOR_DIR)/
	cp node_modules/chartjs-plugin-zoom/dist/chartjs-plugin-zoom.min.js $(VENDOR_DIR)/
	cp node_modules/hammerjs/hammer.min.js $(VENDOR_DIR)/
	cp node_modules/chartjs-plugin-annotation/dist/chartjs-plugin-annotation.min.js $(VENDOR_DIR)/

# Report generation
report: vendor ## Generate performance report from last benchmark run
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi; \
	KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) ./scripts/report-generator/report.sh

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

# Range query test
range-query-test: ## Run PK range query performance test
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) ./scripts/range-query-test.sh

# CDC pipeline (MariaDB -> Debezium -> Kafka -> JDBC Sink -> YugabyteDB)
cdc-deploy: ## Deploy CDC pipeline and register connectors
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) ./cdc/deploy.sh

cdc-test: ## Run CDC replication test (10K updates)
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) ./cdc/run-test.sh

cdc-status: ## Show CDC connector status
	@$(KUBECTL) exec deployment/cdc-kafka-connect -- curl -sf http://localhost:8083/connectors?expand=status 2>/dev/null | python3 -m json.tool || echo "Kafka Connect not ready"

cdc-clean: ## Delete CDC pipeline resources
	@$(KUBECTL) delete -f cdc/ --ignore-not-found

# k3s-virsh infrastructure
setup-k3s-virsh: ## Create VMs and install k3s cluster
	@./scripts/setup-k3s-virsh.sh

teardown-k3s-virsh: ## Destroy VMs and remove k3s cluster
	@./scripts/teardown-k3s-virsh.sh

setup-slow-disk: ## Setup tserver storage with optional dm-delay (DISK_DELAY_MS=50)
	@KUBE_CONTEXT=$(KUBE_CONTEXT) DISK_DELAY_MS=$(DISK_DELAY_MS) ./scripts/setup-slow-disk.sh

setup-slow-throughput: ## Throttle VM disk throughput (DISK_BW_MBPS=10 DISK_IOPS=200)
	@DISK_BW_MBPS=$(DISK_BW_MBPS) DISK_IOPS=$(DISK_IOPS) ./scripts/setup-slow-throughput.sh

adjust-disk-delay: ## Change dm-delay live without destroying data (DISK_DELAY_MS=5)
	@DISK_DELAY_MS=$(DISK_DELAY_MS) ./scripts/adjust-disk-delay.sh

# Cleanup (ENV= COMPONENT=all|yb|bench)
clean: ## Clean components (ENV= COMPONENT=all|yb|bench)
ifeq ($(COMPONENT),all)
	$(MAKE) _clean-bench
	$(MAKE) _clean-yb
else ifeq ($(COMPONENT),yb)
	$(MAKE) _clean-yb
else ifeq ($(COMPONENT),bench)
	$(MAKE) _clean-bench
else
	$(error Unknown COMPONENT=$(COMPONENT). Use: all, yb, bench)
endif

_clean-bench:
	@echo "Uninstalling $(BENCH_RELEASE)..."
	@helm --kube-context $(KUBE_CONTEXT) uninstall $(BENCH_RELEASE) -n $(NAMESPACE) 2>/dev/null || true

_clean-yb:
	@echo "Uninstalling $(YB_RELEASE)..."
	@helm --kube-context $(KUBE_CONTEXT) uninstall $(YB_RELEASE) -n $(NAMESPACE) 2>/dev/null || true
	@echo "Deleting PVCs..."
	@$(KUBECTL) delete pvc -l app=yb-tserver 2>/dev/null || true
	@$(KUBECTL) delete pvc -l app=yb-master 2>/dev/null || true
	@echo "Deleting namespace..."
	@kubectl --context $(KUBE_CONTEXT) delete namespace $(NAMESPACE) --ignore-not-found
