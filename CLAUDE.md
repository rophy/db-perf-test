**IMPORTANT**: The host machine may run multiple projects with different Kubernetes clusters simultaneously. To prevent conflicts:

### Analysis & Debugging
- **NEVER** make claims about root causes or bottlenecks without direct measurement evidence
- **ALWAYS** clearly distinguish between measured facts and hypotheses
- When a measurement disproves a hypothesis, acknowledge it — do not shift to a new unverified claim
- If the root cause is unknown, say so — do not speculate as if it were fact

### Warmup vs Heat (steady-state)
Every benchmark run has a **warmup** phase followed by a **heat** (steady-state) phase.
`values-*.yaml` sets `sysbench.warmupTime` (e.g. 90s); `sysbench_times.txt` records
`RUN_START_TIME`, `WARMUP_END_TIME`, and `RUN_END_TIME` so the split is explicit.

- **NEVER** compare run-averaged numbers across iterations. Averaging warmup in drags
  metrics down in different amounts depending on run length, threads, and cluster size,
  producing apples-to-oranges comparisons.
- **ALWAYS** read the per-interval table in `summary.txt` (or the HTML report) and compare
  **post-warmup rows only** (rows where `Phase == run`). Eyeball where CPU / TPS actually
  stabilize — the warmup boundary is a labeling hint, not a guarantee of steady-state
  (CPU instrumentation can lag ~30-60s past `WARMUP_END_TIME`).
- The `=== Sysbench Totals ===` block in `summary.txt` is run-averaged by design (sysbench
  reports it that way). Treat those totals as historical reference only; do not cite them
  as throughput or CPU of "the test."
- Historical caution: iter 13-18 analyses were built on a run-averaged CPU of 72.8% that
  looked like "25% headroom"; steady-state was 99%. Six iterations of misdiagnosis
  chased a non-existent coordinator bottleneck. See
  `~/.claude/projects/-home-rophy-projects-db-perf-test/memory/project_cpu_avg_artifact.md`.

### Shell Scripts
- **NEVER** use bare `kubectl` commands that rely on the current context
- **ALWAYS** use explicit `--context` flag: `kubectl --context minikube ...`

### Querying Prometheus
The Prometheus instance is in-cluster as `yb-bench-prometheus` in namespace
`yugabyte-test`. Do NOT port-forward — `kubectl exec` into the pod and curl
localhost from inside:

```bash
PROM=$(kubectl --context kube-sandbox -n yugabyte-test get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}')
kubectl --context kube-sandbox -n yugabyte-test exec $PROM -- wget -qO- \
    "http://localhost:9090/api/v1/query_range?query=...&start=...&end=...&step=10"
```

`wget` is what's installed in the prom/prometheus image (no curl). Use the
epoch timestamps from `output/sysbench/sysbench_times.txt` (or the report
directory copy) to scope `query_range` to the run window.

### Running Benchmarks
- **ALWAYS** follow `README.md` for benchmark instructions
- **ALWAYS** use Makefile targets (`make sysbench-prepare`, `make sysbench-run`, `make report`) instead of ad-hoc commands
- **ALWAYS** run `make sysbench-cleanup && make sysbench-prepare && make sysbench-trigger` before EVERY benchmark run whose results will be compared across runs.
  - sysbench `oltp_insert` appends rows; row counts grow across runs.
  - The `cleanup_duplicate_k` trigger's SELECT-before-INSERT slows as tables grow, so per-op cost drifts and TPS numbers across back-to-back runs without reset are not comparable.
  - `make sysbench-trigger` installs the trigger on ALL sbtest tables. It MUST be run after every `make sysbench-prepare` because prepare recreates the tables (dropping triggers).
  - This applies even when only a gflag changes between runs. Redeploying does not reset table state; PVCs persist.
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
