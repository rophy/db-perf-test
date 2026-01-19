**IMPORTANT**: The host machine may run multiple projects with different Kubernetes clusters simultaneously. To prevent conflicts:

### Shell Scripts
- **NEVER** use bare `kubectl` commands that rely on the current context
- **ALWAYS** use explicit `--context` flag: `kubectl --context minikube ...`

### Running Benchmarks
- **ALWAYS** follow `README.md` for benchmark instructions
- Use Makefile targets (`make sysbench-prepare`, `make sysbench-run`, `make report`) instead of ad-hoc commands

### Kubernetes Resource Changes
- **NEVER** update Kubernetes resources manually with `kubectl set`, `kubectl patch`, or `kubectl create`
- **ALWAYS** update manifest files in `k8s/` and apply with `kubectl apply -k` or `helm upgrade`
- This ensures all changes are tracked in git and can be committed
