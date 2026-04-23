**IMPORTANT**: When user asks to update CLAUDE.md, update AGENT.md instead.

**IMPORTANT**: The host machine may run multiple projects with different Kubernetes clusters simultaneously. To prevent conflicts:

### Analysis & Debugging
- **NEVER** make claims about root causes or bottlenecks without direct measurement evidence
- **ALWAYS** clearly distinguish between measured facts and hypotheses
- When a measurement disproves a hypothesis, acknowledge it — do not shift to a new unverified claim
- If the root cause is unknown, say so — do not speculate as if it were fact

### Warmup vs Heat (steady-state)
Every benchmark run has a **warmup** phase followed by a **heat** (steady-state) phase.
`values-*.yaml` sets `sysbench.warmupTime` (e.g. 90s); `output/test_times.txt` records
`WORKLOAD_TYPE`, `RUN_START_TIME`, `WARMUP_END_TIME`, and `RUN_END_TIME` so the split is explicit.

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
The Prometheus instance is in-cluster (label `app.kubernetes.io/component=prometheus`)
in namespace `yugabyte-test`. Do NOT port-forward — `kubectl exec` into the pod and curl
localhost from inside:

```bash
PROM=$(kubectl --context $KUBE_CONTEXT -n yugabyte-test get pod -l app.kubernetes.io/component=prometheus -o jsonpath='{.items[0].metadata.name}')
kubectl --context $KUBE_CONTEXT -n yugabyte-test exec $PROM -- wget -qO- \
    "http://localhost:9090/api/v1/query_range?query=...&start=...&end=...&step=10"
```

`wget` is what's installed in the prom/prometheus image (no curl). Use the
epoch timestamps from `output/test_times.txt` (or the report
directory copy) to scope `query_range` to the run window.

### Running Benchmarks
- **ALWAYS** follow `README.md` for benchmark instructions
- **ALWAYS** use Makefile targets (`make sysbench-prepare`, `make sysbench-run`, `make report`) instead of ad-hoc commands
- **ALWAYS** run `make sysbench-cleanup && make sysbench-prepare && make sysbench-trigger` before EVERY benchmark run whose results will be compared across runs.
  - sysbench `oltp_insert` appends rows; row counts grow across runs.
  - `make sysbench-trigger` installs the trigger on ALL sbtest tables. It MUST be run after every `make sysbench-prepare` because prepare recreates the tables (dropping triggers).
  - This applies even when only a gflag changes between runs. Redeploying does not reset table state; PVCs persist.
- **NEVER** run `sysbench` directly via `kubectl exec ... -- sysbench ...`
  - This bypasses the entrypoint script which sets critical YugabyteDB-specific flags (e.g., `--range_selects=false`)

### Per-Run Analysis (`analysis.md`)
After `make report` completes, write `reports/<timestamp>/analysis.md` for the run.
The file is the durable record of what was tested, what was observed, and what to do next.

Format (see existing `reports/*/analysis.md` for examples):
- Title with iter number + one-line takeaway
- Config block (cluster size, threads, gflags, what changed vs. previous iter)
- Hypothesis under test
- Result — read **per-interval** TPS / CPU from `summary.txt`, NOT the run-averaged totals
- Comparison table vs. previous iter
- Verdict + recommended next steps

**If the result isn't ideal — STOP before writing the verdict.** Do not jump to a conclusion
from sysbench numbers alone. The sysbench output is one viewpoint and frequently misleads
(see iter 13–18: a CPU-averaging artifact created six iterations of wrong conclusions; see
iter 19: the "TPS collapse" was a sysbench reporter artifact, not real cluster behavior).

Before committing to an interpretation:
1. **Pull Prometheus metrics for the run window** (per-tserver Write RPC rate, CPU per
   container, WAL fsync latency, compaction debt, network, disk %busy, master CPU). Recipe
   in the "Querying Prometheus" section above.
2. **Cross-check sysbench's story against the DB-side metrics.** If sysbench TPS dropped 50%
   but per-tserver Write RPC rate dropped <10%, the bottleneck is in the reporter or the
   client, not the cluster.
3. **Check both ends of the path** — client node CPU, network saturation, master CPU/throttle,
   tserver CPU per container vs. node, per-tserver write asymmetry.
4. Only after the metrics agree on a story, write the verdict. If they don't agree, say
   "unknown — these signals conflict" rather than picking the most plausible-sounding one.

### Long-Running Make Targets
- When running `make deploy`, `make sysbench-*`, or other long-running targets:
  - **ALWAYS** run in background using `run_in_background: true`
  - **CONTINUOUSLY** monitor status with `make status` and pod logs to confirm tasks are not stuck
  - Check for errors in pod events and logs if tasks appear stalled

### Metrics Dump Storage
- Report metrics dumps (`metrics_dump.json.gz`) are stored in S3, not git
- Set `METRICS_DUMP_BASE_URL` env var to enable S3 upload during `make report`
- Example: `METRICS_DUMP_BASE_URL="https://db-perf-test-ape2.s3.ap-east-2.amazonaws.com" make report`
- Without the env var, dumps are saved locally and report uses relative path

### Kubernetes Resource Changes
- **NEVER** update Kubernetes resources manually with `kubectl set`, `kubectl patch`, or `kubectl create`
- **ALWAYS** update manifest files in `k8s/` and apply with `kubectl apply -k` or `helm upgrade`
- This ensures all changes are tracked in git and can be committed
