.PHONY: help deploy clean status ysql
.PHONY: sysbench-prepare sysbench-run sysbench-cleanup sysbench-shell sysbench-logs sysbench-trigger
.PHONY: k6-run k6-shell
.PHONY: report vendor
.PHONY: range-query-test
.PHONY: cdc-deploy cdc-test cdc-status cdc-clean
.PHONY: setup-k3s-virsh teardown-k3s-virsh setup-vm-virsh teardown-vm-virsh
.PHONY: setup-slow-disk setup-slow-throughput adjust-disk-delay

# Environment and component selection
ENV ?= k3s-virsh
COMPONENT ?= all

NAMESPACE ?= yugabyte-test

# Detect VM-based environments
IS_VM_ENV := $(filter vm-virsh,$(ENV))

# Map ENV to kube context
KUBE_CONTEXT_aws := kube-sandbox
KUBE_CONTEXT_minikube := minikube
KUBE_CONTEXT_k3s-virsh := k3s-virsh
KUBE_CONTEXT_kind := kind-kind
KUBE_CONTEXT_vm-virsh := kind-kind
KUBE_CONTEXT := $(KUBE_CONTEXT_$(ENV))

# VM-specific variables
ifdef IS_VM_ENV
VM_DIR := .vms
SSH_OPTS := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
YB_ANSIBLE_DIR ?= $(HOME)/projects/yb-ansible
endif

# Two independent Helm releases
YB_RELEASE := yugabyte
YB_CHART_DIR := charts/yugabyte
BENCH_RELEASE := yb-benchmark
BENCH_CHART_DIR := charts/yb-benchmark

RELEASE_NAME := $(BENCH_RELEASE)

# Slow disk simulation parameters
DISK_DELAY_MS ?= 0
DISK_BW_MBPS ?= 0
DISK_IOPS ?= 0

KUBECTL := kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE)
SYSBENCH_POD := $(BENCH_RELEASE)-sysbench-0

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Deployment (ENV=k3s-virsh|aws|minikube|kind|vm-virsh  COMPONENT=all|yb|bench)
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

ifdef IS_VM_ENV
_deploy-yb:
	@echo "Deploying YugabyteDB via yb-ansible..."
	cd $(YB_ANSIBLE_DIR) && ansible-playbook deploy.yml -i $(CURDIR)/ansible/inventory/vm-virsh.ini
else
_deploy-yb:
	@helm upgrade --install $(YB_RELEASE) $(YB_CHART_DIR) \
		--kube-context $(KUBE_CONTEXT) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		-f $(YB_CHART_DIR)/values-$(ENV).yaml \
		--wait --timeout 15m
endif

_deploy-bench:
ifdef IS_VM_ENV
	@./scripts/gen-values-vm-virsh.sh
endif
	@helm upgrade --install $(BENCH_RELEASE) $(BENCH_CHART_DIR) \
		--kube-context $(KUBE_CONTEXT) \
		--namespace $(NAMESPACE) \
		--create-namespace \
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

K6_POD := $(BENCH_RELEASE)-k6-0
K6_SCRIPT ?= test.js

# k6 operations
ifdef IS_VM_ENV
k6-run: ## Run k6 benchmark with timestamps
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) K6_SCRIPT=$(K6_SCRIPT) \
		./scripts/k6-run-with-timestamps-vm.sh
else
k6-run:
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) K6_SCRIPT=$(K6_SCRIPT) \
		./scripts/k6-run-with-timestamps.sh
endif

k6-shell: ## Open shell in k6 pod
	$(KUBECTL) exec -it $(K6_POD) -- /bin/sh

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
ifdef IS_VM_ENV
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi; \
	IS_VM_ENV=1 KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) ./scripts/report-generator/report.sh
else
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi; \
	KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) ./scripts/report-generator/report.sh
endif

# Utilities
ifdef IS_VM_ENV
status: ## Show status of all components
	@echo "=== VMs ==="
	@virsh list --all | grep ygvm || true
	@echo ""
	@echo "=== VM IPs ==="
	@cat $(VM_DIR)/vm-ips.env 2>/dev/null || echo "No vm-ips.env found. Run: make setup-vm-virsh"
	@echo ""
	@echo "=== YB Masters ==="
	@for var in $$(grep "^MASTER_.*_IP=" $(VM_DIR)/vm-ips.env 2>/dev/null | sort); do \
		ip=$$(echo "$$var" | cut -d= -f2); \
		name=$$(echo "$$var" | cut -d= -f1 | sed 's/_IP$$//' | tr '[:upper:]' '[:lower:]' | tr '_' '-'); \
		status=$$(ssh $(SSH_OPTS) ubuntu@$$ip "systemctl is-active yb-master" 2>/dev/null || echo "unknown"); \
		echo "  $$name ($$ip): $$status"; \
	done
	@echo ""
	@echo "=== YB TServers ==="
	@for var in $$(grep "^TSERVER_.*_IP=" $(VM_DIR)/vm-ips.env 2>/dev/null | sort); do \
		ip=$$(echo "$$var" | cut -d= -f2); \
		name=$$(echo "$$var" | cut -d= -f1 | sed 's/_IP$$//' | tr '[:upper:]' '[:lower:]' | tr '_' '-'); \
		status=$$(ssh $(SSH_OPTS) ubuntu@$$ip "systemctl is-active yb-tserver" 2>/dev/null || echo "unknown"); \
		echo "  $$name ($$ip): $$status"; \
	done
	@echo ""
	@echo "=== Bench Pods (kind) ==="
	@$(KUBECTL) get pods -o wide 2>/dev/null || echo "No kind cluster or bench not deployed"

ysql: ## Connect to YugabyteDB YSQL shell
	@TSERVER_IP=$$(grep TSERVER_1_IP $(VM_DIR)/vm-ips.env | cut -d= -f2); \
	MASTER_IP=$$(grep MASTER_1_IP $(VM_DIR)/vm-ips.env | cut -d= -f2); \
	ssh $(SSH_OPTS) ubuntu@$$MASTER_IP "/opt/yugabyte/bin/ysqlsh -h $$TSERVER_IP"
else
status:
	@echo "=== Pods ==="
	@$(KUBECTL) get pods -o wide
	@echo ""
	@echo "=== Services ==="
	@$(KUBECTL) get svc

ysql:
	$(KUBECTL) exec -it yb-tserver-0 -- /home/yugabyte/bin/ysqlsh -h yb-tserver-service
endif

port-forward-metrics: ## Port forward VictoriaMetrics to localhost:8428
	$(KUBECTL) port-forward svc/$(shell $(KUBECTL) get svc -l app.kubernetes.io/component=victoriametrics -o jsonpath='{.items[0].metadata.name}') 8428:8428

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

# vm-virsh infrastructure (raw VMs, no k8s)
setup-vm-virsh: ## Create VMs for raw VM deployment
	@./scripts/setup-vm-virsh.sh

teardown-vm-virsh: ## Destroy raw VM deployment VMs
	@./scripts/teardown-vm-virsh.sh

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

ifdef IS_VM_ENV
_clean-yb:
	@echo "Stopping YugabyteDB on VMs via yb-ansible..."
	cd $(YB_ANSIBLE_DIR) && ansible-playbook clean.yml -i $(CURDIR)/ansible/inventory/vm-virsh.ini
else
_clean-yb:
	@echo "Uninstalling $(YB_RELEASE)..."
	@helm --kube-context $(KUBE_CONTEXT) uninstall $(YB_RELEASE) -n $(NAMESPACE) 2>/dev/null || true
	@echo "Deleting PVCs..."
	@$(KUBECTL) delete pvc -l app=yb-tserver 2>/dev/null || true
	@$(KUBECTL) delete pvc -l app=yb-master 2>/dev/null || true
	@echo "Deleting namespace..."
	@kubectl --context $(KUBE_CONTEXT) delete namespace $(NAMESPACE) --ignore-not-found
endif
