.PHONY: help setup-minikube setup-aws deploy build-schema run-bench delete-schema clean status logs ysql

ENV ?= minikube
KUBE_CONTEXT ?= minikube

# HammerDB benchmark settings
HAMMERDB_WAREHOUSES ?= 4
HAMMERDB_VUS ?= 4
HAMMERDB_DURATION ?= 5
HAMMERDB_RAMPUP ?= 1

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Setup targets
setup-minikube: ## Setup YugabyteDB on minikube
	@./scripts/setup-minikube.sh

setup-aws: ## Setup infrastructure on AWS
	@./scripts/setup-aws.sh

# Deployment targets
deploy: ## Deploy HammerDB and Prometheus (ENV=minikube|aws)
	@ENV=$(ENV) KUBE_CONTEXT=$(KUBE_CONTEXT) ./scripts/deploy.sh

# HammerDB operations
build-schema: ## Build TPROC-C schema in YugabyteDB
	@echo "Building TPROC-C schema (warehouses: $(HAMMERDB_WAREHOUSES), vus: $(HAMMERDB_VUS))..."
	@kubectl --context $(KUBE_CONTEXT) exec -n yugabyte-test deployment/hammerdb -- \
		env HAMMERDB_WAREHOUSES=$(HAMMERDB_WAREHOUSES) HAMMERDB_VUS=$(HAMMERDB_VUS) \
		/scripts/entrypoint.sh build

run-bench: ## Run TPROC-C benchmark
	@echo "Running TPROC-C benchmark (vus: $(HAMMERDB_VUS), duration: $(HAMMERDB_DURATION) min)..."
	@kubectl --context $(KUBE_CONTEXT) exec -n yugabyte-test deployment/hammerdb -- \
		env HAMMERDB_VUS=$(HAMMERDB_VUS) HAMMERDB_DURATION=$(HAMMERDB_DURATION) HAMMERDB_RAMPUP=$(HAMMERDB_RAMPUP) \
		/scripts/entrypoint.sh run

delete-schema: ## Delete TPROC-C schema from YugabyteDB
	@echo "Deleting TPROC-C schema..."
	@kubectl --context $(KUBE_CONTEXT) exec -n yugabyte-test deployment/hammerdb -- \
		/scripts/entrypoint.sh delete

hammerdb-shell: ## Open HammerDB CLI shell
	@kubectl --context $(KUBE_CONTEXT) exec -it -n yugabyte-test deployment/hammerdb -- \
		/scripts/entrypoint.sh shell

# Monitoring
status: ## Show status of all components
	@echo "=== Pods ==="
	@kubectl --context $(KUBE_CONTEXT) get pods -n yugabyte-test
	@echo ""
	@echo "=== Services ==="
	@kubectl --context $(KUBE_CONTEXT) get svc -n yugabyte-test

logs: ## Show HammerDB logs
	@kubectl --context $(KUBE_CONTEXT) logs -f deployment/hammerdb -n yugabyte-test

# Database access
ysql: ## Connect to YugabyteDB YSQL shell
	@kubectl --context $(KUBE_CONTEXT) exec -it -n yugabyte-test yb-tserver-0 -- /home/yugabyte/bin/ysqlsh -h localhost

# Port forwarding
port-forward-prometheus: ## Port forward Prometheus to localhost:9090
	@kubectl --context $(KUBE_CONTEXT) port-forward svc/prometheus 9090:9090 -n yugabyte-test

port-forward-yugabyte: ## Port forward YugabyteDB YSQL to localhost:5433
	@kubectl --context $(KUBE_CONTEXT) port-forward svc/yb-tservers 5433:5433 -n yugabyte-test

# Cleanup
clean: ## Delete all resources in the namespace
	@echo "Deleting all resources in yugabyte-test namespace..."
	@kubectl --context $(KUBE_CONTEXT) delete namespace yugabyte-test --ignore-not-found
	@echo "Uninstalling Helm releases..."
	@helm --kube-context $(KUBE_CONTEXT) uninstall yugabyte -n yugabyte-test 2>/dev/null || true
