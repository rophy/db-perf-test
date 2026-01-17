.PHONY: help setup-minikube setup-aws deploy build-producer push-producer run-test clean status logs

ENV ?= minikube
KUBE_CONTEXT ?= minikube
REGISTRY ?= localhost:5000
PRODUCER_IMAGE ?= $(REGISTRY)/cdc-producer:latest
EVENTS_PER_SECOND ?= 1000
THREADS ?= 4
MODE ?= both

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Setup targets
setup-minikube: ## Setup infrastructure on minikube
	@./scripts/setup-minikube.sh

setup-aws: ## Setup infrastructure on AWS
	@./scripts/setup-aws.sh

# Build targets
build-producer: ## Build the CDC producer Docker image
	@echo "Building CDC producer..."
	@cd producers && docker build -t $(PRODUCER_IMAGE) .

push-producer: build-producer ## Push the CDC producer image to registry
	@echo "Pushing CDC producer image..."
	@docker push $(PRODUCER_IMAGE)

# For minikube, load image directly
load-producer-minikube: build-producer ## Load producer image into minikube
	@echo "Loading image into minikube..."
	@minikube image load $(PRODUCER_IMAGE)

# Deployment targets
deploy: ## Deploy all components (ENV=minikube|aws)
	@ENV=$(ENV) KUBE_CONTEXT=$(KUBE_CONTEXT) ./scripts/deploy.sh

deploy-producer: ## Deploy only the CDC producer
	@kubectl --context $(KUBE_CONTEXT) apply -f k8s/base/producer/producer.yaml

# Test targets
run-test: ## Run the load test (EVENTS_PER_SECOND, THREADS, MODE)
	@KUBE_CONTEXT=$(KUBE_CONTEXT) ./scripts/run-test.sh $(EVENTS_PER_SECOND) $(THREADS) $(MODE)

stop-producer: ## Stop the CDC producer
	@kubectl --context $(KUBE_CONTEXT) scale deployment/cdc-producer --replicas=0 -n yugabyte-test

start-producer: ## Start the CDC producer
	@kubectl --context $(KUBE_CONTEXT) scale deployment/cdc-producer --replicas=1 -n yugabyte-test

# Monitoring
status: ## Show status of all components
	@echo "=== Pods ==="
	@kubectl --context $(KUBE_CONTEXT) get pods -n yugabyte-test
	@echo ""
	@echo "=== Kafka Topics ==="
	@kubectl --context $(KUBE_CONTEXT) get kafkatopics -n yugabyte-test 2>/dev/null || echo "No Kafka topics found"
	@echo ""
	@echo "=== Kafka Connectors ==="
	@kubectl --context $(KUBE_CONTEXT) get kafkaconnectors -n yugabyte-test 2>/dev/null || echo "No Kafka connectors found"

logs: ## Show CDC producer logs
	@kubectl --context $(KUBE_CONTEXT) logs -f deployment/cdc-producer -n yugabyte-test

logs-kafka: ## Show Kafka logs
	@kubectl --context $(KUBE_CONTEXT) logs -f kafka-cluster-kafka-0 -n yugabyte-test

logs-connect: ## Show Kafka Connect logs
	@kubectl --context $(KUBE_CONTEXT) logs -f deployment/kafka-connect-connect -n yugabyte-test 2>/dev/null || \
		kubectl --context $(KUBE_CONTEXT) logs -l strimzi.io/kind=KafkaConnect -n yugabyte-test

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
	@helm --kube-context $(KUBE_CONTEXT) uninstall strimzi-kafka-operator -n yugabyte-test 2>/dev/null || true

clean-producer: ## Delete only the producer resources
	@kubectl --context $(KUBE_CONTEXT) delete -f k8s/base/producer/producer.yaml --ignore-not-found
