**IMPORTANT**: The host machine may run multiple projects with different Kubernetes clusters simultaneously. To prevent conflicts:

### Shell Scripts
- **NEVER** use bare `kubectl` commands that rely on the current context
- **ALWAYS** use explicit `--context` flag: `kubectl --context minikube ...`

### Running Benchmarks
- **ALWAYS** follow `README.md` for benchmark instructions
- **ALWAYS** use Makefile targets (`make sysbench-prepare`, `make sysbench-run`, `make report`) instead of ad-hoc commands
- **NEVER** run `sysbench` directly via `kubectl exec ... -- sysbench ...`
  - This bypasses the entrypoint script which sets critical YugabyteDB-specific flags (e.g., `--range_selects=false`)
  - Missing these flags causes 100x+ performance degradation due to cross-tablet range scans
- If you need to run with different parameters, use environment variables with the entrypoint:
  ```bash
  kubectl exec deployment/sysbench -- env SYSBENCH_THREADS=90 /scripts/entrypoint.sh run
  ```

### Long-Running Make Targets
- When running `make deploy-*`, `make sysbench-*`, or other long-running targets:
  - **ALWAYS** run in background using `run_in_background: true`
  - **CONTINUOUSLY** monitor status with `make status` and pod logs to confirm tasks are not stuck
  - Check for errors in pod events and logs if tasks appear stalled

### Kubernetes Resource Changes
- **NEVER** update Kubernetes resources manually with `kubectl set`, `kubectl patch`, or `kubectl create`
- **ALWAYS** update manifest files in `k8s/` and apply with `kubectl apply -k` or `helm upgrade`
- This ensures all changes are tracked in git and can be committed
