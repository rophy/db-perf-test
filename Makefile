.PHONY: help deploy deploy-yugabyte clean status ysql
.PHONY: hammerdb-build hammerdb-run hammerdb-shell hammerdb-logs
.PHONY: sysbench-prepare sysbench-run sysbench-cleanup sysbench-shell sysbench-logs sysbench-config
.PHONY: report

KUBE_CONTEXT ?= minikube

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Deployment
deploy: ## Deploy sysbench, hammerdb, prometheus
	@KUBE_CONTEXT=$(KUBE_CONTEXT) ./scripts/deploy.sh

deploy-yugabyte: ## Deploy YugabyteDB via helm
	@helm repo add yugabytedb https://charts.yugabyte.com 2>/dev/null || true
	@helm repo update yugabytedb
	@helm upgrade --install yugabyte yugabytedb/yugabyte \
		--kube-context $(KUBE_CONTEXT) \
		--namespace yugabyte-test \
		--create-namespace \
		--values k8s/yugabytedb-values.yaml \
		--wait --timeout 15m

# Sysbench operations (uses entrypoint with YugabyteDB-optimized flags)
sysbench-prepare: ## Prepare sysbench tables (20 tables x 5M rows per YB docs)
	@kubectl --context $(KUBE_CONTEXT) exec -n yugabyte-test deployment/sysbench -- \
		/scripts/entrypoint.sh prepare

sysbench-run: ## Run sysbench benchmark (1800s per YB docs)
	@KUBE_CONTEXT=$(KUBE_CONTEXT) ./scripts/sysbench-run-with-timestamps.sh

sysbench-cleanup: ## Cleanup sysbench tables
	@kubectl --context $(KUBE_CONTEXT) exec -n yugabyte-test deployment/sysbench -- \
		/scripts/entrypoint.sh cleanup

sysbench-config: ## Show sysbench configuration
	@kubectl --context $(KUBE_CONTEXT) exec -n yugabyte-test deployment/sysbench -- \
		/scripts/entrypoint.sh config

sysbench-shell: ## Open shell in sysbench container
	@kubectl --context $(KUBE_CONTEXT) exec -it -n yugabyte-test deployment/sysbench -- /bin/bash

sysbench-logs: ## Show sysbench container logs
	@kubectl --context $(KUBE_CONTEXT) logs -f deployment/sysbench -n yugabyte-test

# HammerDB operations
hammerdb-build: ## Build TPROC-C schema
	@kubectl --context $(KUBE_CONTEXT) exec -n yugabyte-test deployment/hammerdb -- \
		/scripts/entrypoint.sh build

hammerdb-run: ## Run TPROC-C benchmark
	@kubectl --context $(KUBE_CONTEXT) exec -n yugabyte-test deployment/hammerdb -- \
		/scripts/entrypoint.sh run

hammerdb-shell: ## Open HammerDB shell
	@kubectl --context $(KUBE_CONTEXT) exec -it -n yugabyte-test deployment/hammerdb -- \
		/scripts/entrypoint.sh shell

hammerdb-logs: ## Show HammerDB logs
	@kubectl --context $(KUBE_CONTEXT) logs -f deployment/hammerdb -n yugabyte-test

# Report generation
report: ## Generate performance report from last benchmark run
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=yugabyte-test ./scripts/report-generator/report.sh

# Utilities
status: ## Show status of all components
	@echo "=== Pods ==="
	@kubectl --context $(KUBE_CONTEXT) get pods -n yugabyte-test -o wide
	@echo ""
	@echo "=== Services ==="
	@kubectl --context $(KUBE_CONTEXT) get svc -n yugabyte-test

ysql: ## Connect to YugabyteDB YSQL shell
	@kubectl --context $(KUBE_CONTEXT) exec -it -n yugabyte-test yb-tserver-0 -- \
		/home/yugabyte/bin/ysqlsh -h yb-tserver-service

port-forward-prometheus: ## Port forward Prometheus to localhost:9090
	@kubectl --context $(KUBE_CONTEXT) port-forward svc/prometheus 9090:9090 -n yugabyte-test

# Cleanup
clean: ## Delete all resources
	@echo "Uninstalling YugabyteDB..."
	@helm --kube-context $(KUBE_CONTEXT) uninstall yugabyte -n yugabyte-test 2>/dev/null || true
	@echo "Deleting PVCs..."
	@kubectl --context $(KUBE_CONTEXT) delete pvc -n yugabyte-test -l app=yb-tserver 2>/dev/null || true
	@kubectl --context $(KUBE_CONTEXT) delete pvc -n yugabyte-test -l app=yb-master 2>/dev/null || true
	@echo "Deleting namespace..."
	@kubectl --context $(KUBE_CONTEXT) delete namespace yugabyte-test --ignore-not-found
