# Implementation Plan — Issue #2 + Interactive Report

**Goal:** fix the CPU chart correctness issues reported in GitHub issue #2
(`rophy/db-perf-test#2`) and rebuild the HTML report as an interactive,
tabbed, pod-centric view.

This plan is self-contained; a fresh session should be able to pick it up
without extra context. When starting work, read this file first, then
`CLAUDE.md` (root), then the files listed under each commit.

---

## Background

### Issue #2 summary
The container CPU chart in `report.html` shows fluctuating values with drops
to near-zero mid-run, despite the cluster being CPU-saturated (node-level CPU
shows steady 94%).

Root causes called out in the issue:
1. cAdvisor counter stalls — `container_cpu_usage_seconds_total` occasionally
   reports stale counters, causing `rate()` to compute near-zero.
2. `rate([30s])` with 15s scrape — only 2 samples per window; one bad sample
   poisons the window.
3. Original query used `container=""` — cAdvisor doesn't reliably emit
   pod-level CPU rows across runtimes.

Issue prescribes:
1. Reduce scrape interval from 15s to 5s.
2. Switch `rate([30s])` → `irate([15s])`.
3. Unify container and node CPU on same chart in cores (drop `* 100`).

### Verified facts (from live Prometheus investigation)

- Both `container_*` (cAdvisor) and `node_*` (node_exporter) metrics carry an
  `instance` label that equals the node hostname (e.g. `ygdb-worker-3`).
  No kube-state-metrics needed for pod→node join.
- Both metric families also carry a `role` label (`master` | `db`) — useful
  to filter queries to just DB nodes when doing cluster-wide aggregates.
- For a yb-tserver pod we observed **five** cAdvisor rows:
  - `container="yb-tserver"` — main container
  - `container="yb-cleanup"` — sidecar
  - `container="yugabyted-ui"` — sidecar
  - `container=""`, image=`<none>` — pod-cgroup (sums all containers)
  - `container=""`, image=`pause:3.6` — sandbox/pause container
- Under `rate()`, pod-cgroup row and per-container sum **drift by ~20–30%**
  because they're not sampled atomically. Per-container sum is the reliable
  choice.
- Portable CPU query (works on k3s, EKS, etc.):
  ```
  sum by (instance, pod) (
    rate(container_cpu_usage_seconds_total{
      namespace="yugabyte-test",
      container!="",
      container!="POD"
    }[15s])
  )
  ```
- Memory: per-container rows exist, pod-cgroup row is accurate. Either works;
  use the same `container!="", container!="POD"` filter for consistency.
- Network: cAdvisor only exports `container=""` rows (shared netns). No
  container filter needed — use queries as-is.
- Disk (`container_fs_*`): per-container rows exist; same filter as CPU.

### Decisions made during discussion

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Use `irate([15s])` for all rates (not `rate([30s])`) | Issue prescribes it; with 5s scrape, `irate[15s]` uses last 2 samples. Charts will be spikier than before — accepted tradeoff for catching transient spikes. |
| 2 | Prometheus `query_range` `step=10s` | 300s run → 30 points per chart. Good balance of detail vs render cost. |
| 3 | Leave `charts/yb-benchmark/values-aws.yaml` untouched | In-progress iter-25 config; unrelated to issue #2. |
| 4 | Validate on k3s-virsh (context `k3s-virsh`) | AWS cluster is down; use local k3s for iteration. |
| 5 | Three pod buckets: `yb-master`, `tservers`, `others` | yb-master workload differs from tservers; sysbench and misc pods get their own tab. |
| 6 | Two-PR mindset (but focus on clean commits, not PRs) | Correctness fixes land separable from UI rebuild. |
| 7 | Add Chart.js plugins (zoom, annotation, crosshair, CSV export) — ~100KB inline is fine | User confirmed HTML performance not a concern. |
| 8 | Default: show pod-total only. Hide per-container sidecar breakdown. | Sidecars are ~1% of main container load; toggle is easy follow-up. |

### Out of scope (for this plan)
- Per-container sidecar breakdown toggle.
- YB SLI metrics (rows_inserted, Write/Read/UpdateTxn RPCs, conflicts, WAL
  latency, etc.) — tracked in issue #1, separate effort.
- AWS cluster validation — separate iter.
- Any changes to `values-aws.yaml`.

---

## Files in scope

| File | Role |
|---|---|
| `scripts/report-generator/generate_report.py` | Prometheus queries, data shaping |
| `scripts/report-generator/report_template.html` | Jinja2 template + Chart.js JS |
| `charts/yb-benchmark/templates/prometheus.yaml` | scrape_interval (5s already set in working tree) |
| `charts/yb-benchmark/values-k3s-virsh.yaml` | existing user WIP — leave alone |
| `charts/yb-benchmark/values-aws.yaml` | **do not touch** |

---

## Commit 1 — Fix Prometheus queries for correctness

**File:** `scripts/report-generator/generate_report.py`

**Concrete changes (line numbers approximate, current tree):**

1. Around line 283–284, remove the single `pod_cgroup = 'container=""'` shared
   variable. Replace with per-metric logic.
2. CPU query (line 287) becomes:
   ```python
   cpu_query = (
       f'sum by (instance, pod) ('
       f'irate(container_cpu_usage_seconds_total{{'
       f'namespace="{self.config.namespace}",'
       f'pod=~"{pods_regex}",'
       f'container!="",container!="POD"'
       f'}}[15s]))'
   )
   ```
   Note: no `* 100` — emit cores. Display name becomes `"CPU Usage (cores)"`.
3. Memory (line 291): same filter (`container!="", container!="POD"`),
   no rate (gauge), sum by `(instance, pod)`.
4. Network RX/TX (lines 295, 299): keep current form (no container filter
   needed, only pod-level rows exist). Change to `irate([15s])` and group
   `by (instance, pod)`.
5. Disk IOPS + throughput (lines 303–315): same filter as CPU, `irate([15s])`,
   `by (instance, pod)`.
6. Node CPU total (line 322): convert to cores.
   ```python
   node_cpu_query = (
       '(count by (instance) (node_cpu_seconds_total{mode="idle"})) '
       '- sum by (instance) (irate(node_cpu_seconds_total{mode="idle"}[15s]))'
   )
   ```
   This emits **cores-used** (num_cpus − idle_rate_sum). Matches container
   CPU units so overlays make sense.
7. Node CPU breakdown by mode (line 327): keep as percent for the breakdown
   chart (user/system/iowait/steal/softirq). These stay as informational
   detail charts.
8. Sysbench steady-state table queries (lines 384, 394, 398, 403, 411):
   - Update rate windows to `irate([15s])`.
   - `cpu_pct` → change to `cpu_cores` (or keep percent if easier; flag in
     table header either way).
   - `client_cpu_cores` already in cores; change its rate to irate.
9. Any other `rate(...[30s])` in the file: audit and replace with
   `irate(...[15s])`. Also fix the "Sysbench Totals" block if it queries
   Prometheus (lines ~469 area).
10. Update display labels throughout:
    - `"CPU Usage (%)"` → `"CPU Usage (cores)"`
    - Axes titles in JS chart creation code.

**Verification during this commit:**
- Run a dry query against the live Prometheus
  (pod `yb-bench-prometheus-*` in `yugabyte-test` on context `k3s-virsh`):
  ```bash
  PROM=$(kubectl --context k3s-virsh -n yugabyte-test get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}')
  kubectl --context k3s-virsh -n yugabyte-test exec $PROM -- wget -qO- \
    'http://localhost:9090/api/v1/query?query=<URL-encoded query>'
  ```
- Compare the new CPU query output for `yb-tserver-0` against per-container
  sum for the same pod. Expect equality (modulo scrape-timing jitter).

**Commit message:**
```
fix(report): correct cAdvisor CPU query and switch to irate

- Replace container="" pod-cgroup filter with container!="",container!="POD"
  (sum of real per-container rows). Pod-cgroup row drifts from per-container
  sum by ~20-30% under rate(). Per-container sum is portable across runtimes.
- Switch all rates from rate([30s]) to irate([15s]); scrape interval already
  dropped to 5s so irate sees 2 samples per window.
- Emit CPU in cores (drop *100). Node CPU also in cores for unit parity.

Fixes #2 correctness portion.
```

---

## Commit 2 — Regroup metrics by (instance, pod, role)

**File:** `scripts/report-generator/generate_report.py`

**Goal:** enable per-pod cards (each card overlays container + its host-node
metrics) in the template.

**Concrete changes:**

1. Extend `MetricSeries` or the aggregator to retain `instance` label
   alongside `pod` on each series. Current `_query_and_aggregate` keys by
   `pod` only — change to key by `(instance, pod)` or store `instance`
   as a field on the series.
2. Add a classifier:
   ```python
   def _classify_pod(pod_name: str) -> str:
       if pod_name.startswith("yb-master"):
           return "master"
       if pod_name.startswith("yb-tserver"):
           return "tserver"
       return "other"
   ```
3. Build a `pod_to_node` dict from `(instance, pod)` tuples seen in query
   results. Export alongside `metrics_data` for template consumption.
4. Reshape `metrics_data` for the template:
   ```python
   metrics_data = {
       "by_pod": {
           "master":  [{"pod": "yb-master-0", "instance": "ygdb-control",
                        "cpu": [...], "memory": [...], "net_rx": [...], ...}, ...],
           "tserver": [...],
           "other":   [...],
       },
       "by_node": {
           "ygdb-worker-1": {"cpu_cores": [...], "memory": [...], ...},
           ...
       },
       # existing cluster-aggregate keys preserved for Overview tab
       "cpu": ..., "memory": ..., "node_cpu": ..., etc.
   }
   ```
5. Keep the existing flat `metrics_data["cpu"]` etc. keys populated so the
   current template (before commit 3) still renders — commit 1 must leave
   the report working.

**Commit message:**
```
refactor(report): group metrics by (instance, pod, role)

Prepare for per-pod interactive cards. Retain instance label on every
series, build a pod->node map, classify pods into master/tserver/other
buckets. Existing flat metrics_data keys remain for the Overview tab.
```

---

## Commit 3 — Rebuild report template with tabbed views

**File:** `scripts/report-generator/report_template.html`

**Layout:**

```
+-----------------------------------------------------------+
| Header (run info, config block)                          |
+-----------------------------------------------------------+
| [Overview] [yb-master] [tservers] [others] [Raw]         |  <- tab bar
+-----------------------------------------------------------+
|                                                           |
|  <tab content>                                            |
|                                                           |
+-----------------------------------------------------------+
```

**Tab contents:**

- **Overview** — current layout: cluster-wide aggregates, steady-state
  per-interval table, sysbench TPS/latency summary.
- **yb-master** — for each master pod, one card:
  ```
  yb-master-0 (on ygdb-control)
  +---------------+---------------+
  |  CPU (cores)  |  Memory (MB)  |
  +---------------+---------------+
  |  Net (MB/s)   |  Disk (MB/s)  |
  +---------------+---------------+
  ```
  Each chart overlays two lines: pod container metric + its host node metric.
  For net/disk the node line may be omitted if node_exporter doesn't expose
  the equivalent (net can be done via `node_network_*`; disk via
  `node_disk_*`). If sources disagree, just show the pod line and document.
- **tservers** — same card structure, one per tserver.
- **others** — sysbench pods + anything else in the namespace.
- **Raw** — existing per-metric cluster charts (container-CPU cluster chart,
  node-CPU charts with mode breakdown). Keeps backward-compat viewing.

**Lazy render:**
- On initial page load, only build the Overview tab's Chart.js instances.
- On first click of a tab, build that tab's charts and cache the Chart
  instances. Subsequent clicks are instant.
- 57 tservers × 4 charts per card = 228 charts on the tservers tab —
  acceptable after first click, avoids blocking initial render.

**CPU unit reconciliation:**
- Container CPU: cores (from commit 1).
- Node CPU: cores-used = num_cpus − idle_rate_sum (from commit 1).
- Both plotted on same Y-axis with title "CPU (cores)".

**Commit message:**
```
feat(report): add tabbed interactive views (master/tserver/others)

Per-pod cards with container+node metric overlays. Lazy-render on tab
switch to avoid DOM blowout on large clusters. Overview and Raw tabs
preserve existing views.
```

---

## Commit 4 — Chart.js plugins: zoom, annotations, crosshair, CSV export

**File:** `scripts/report-generator/report_template.html` (plus inlined
plugin JS).

**Plugins to bundle (inline in HTML):**
- `chartjs-plugin-zoom` — drag-to-zoom X-axis, wheel zoom, double-click reset.
- `chartjs-plugin-annotation` — vertical line at `WARMUP_END_TIME`, grey
  shaded rect from `RUN_START` to `WARMUP_END`.
- Custom crosshair plugin (~30 lines) or `chartjs-plugin-crosshair` if v4
  compatible. Hovering one chart → vertical guide on all charts **in the
  same card**.

**Timestamps:** read from the per-run `sysbench_times.txt` that's already
copied into the report directory. Pass `run_start`, `warmup_end`, `run_end`
to the template as Unix epoch seconds → convert to chart X-coords in JS.

**CSV export:**
- Each chart gets a small "⬇ CSV" button (top-right of canvas).
- On click: serialize `{datasets: [{label, data: [{x, y}]}]}` to CSV and
  trigger a download. ~30 lines of JS.

**Reset zoom:** one button per card resets all charts in that card.

**Optional enhancement** — if `not_leader_rejections` Prometheus metric is
present in the query result set, add red annotation points where rate > 5K/s
(split-storm diagnostic). Skip gracefully if not queried in this pass.

**Commit message:**
```
feat(report): interactive chart UX (zoom, warmup shading, crosshair, CSV)

- chartjs-plugin-zoom for drag/wheel zoom, reset button per card.
- chartjs-plugin-annotation for warmup shading and WARMUP_END vertical line.
- Shared crosshair within each card; hovering one chart highlights all.
- Per-chart CSV export for ad-hoc analysis.
```

---

## Commit 5 — Validate on k3s-virsh

**No code changes** (unless bugs surface; follow-up commits for fixes).

**Steps:**

1. Confirm context: `kubectl config current-context` should be `k3s-virsh`
   (or explicitly pass `--context k3s-virsh`).
2. Re-deploy prometheus with 5s scrape if not already:
   ```bash
   helm upgrade yb-bench charts/yb-benchmark -f charts/yb-benchmark/values-k3s-virsh.yaml \
     --kube-context k3s-virsh -n yugabyte-test
   ```
3. Clean + prepare + trigger + run:
   ```bash
   make sysbench-cleanup
   make sysbench-prepare
   make sysbench-trigger
   make sysbench-run    # long-running — run_in_background, monitor via make status
   ```
   Per CLAUDE.md, `sysbench-trigger` MUST run after every prepare.
4. Generate report:
   ```bash
   PATH="$(pwd)/.venv/bin:$PATH" make report
   ```
5. Open `reports/<timestamp>/report.html` and verify:
   - CPU chart has no zero-drops (primary issue #2 symptom).
   - Per-pod container CPU (cores) ≤ node CPU (cores) for the same node.
   - Warmup region visually shaded; steady-state clearly visible.
   - Tab switching responsive.
   - Drag-zoom works; reset works.
   - CSV download works.
   - Crosshair syncs within a card.
6. Write `reports/<timestamp>/analysis.md` per CLAUDE.md conventions:
   - Title with one-line takeaway.
   - Config block (this is a report-tooling validation run, note the
     baseline sysbench config).
   - Hypothesis under test: "new queries eliminate zero-drops".
   - Result: read **per-interval rows only** (steady-state), not run-averaged.
   - Verdict + recommended next steps.
7. Log follow-up tasks for any bugs found.

**CLAUDE.md compliance checklist for this step:**
- [ ] Explicit `--context k3s-virsh` on every kubectl.
- [ ] Full test output to a temp file; grep from there.
- [ ] `sysbench-cleanup && sysbench-prepare && sysbench-trigger` before run.
- [ ] Do not directly invoke `sysbench` via `kubectl exec`.
- [ ] `analysis.md` reads steady-state only, not run-averaged totals.
- [ ] No claims of root cause without Prometheus cross-check.

---

## Working notes for the implementing session

- Run `git status` first — expect existing diffs in
  `charts/yb-benchmark/templates/prometheus.yaml` (scrape=5s, keep),
  `values-aws.yaml` (leave alone), `values-k3s-virsh.yaml` (leave alone),
  and `scripts/report-generator/generate_report.py` (this is stale — will be
  overwritten by commit 1).
- Before commit 1, confirm the existing Prometheus is still up on k3s-virsh
  (`kubectl --context k3s-virsh -n yugabyte-test get pod -l app=prometheus`).
  If so, dry-query the new CPU expression there to confirm it returns
  nonzero values.
- The `.venv/` at project root has Jinja2 installed — use it for `make report`.
- Commit messages follow the user's global policy: no "Generated with Claude"
  footer, no Co-Authored-By, no mention of Claude. Types: feat/fix/refactor/
  chore/docs/build/test. Keep messages 1–5 lines.
- Do NOT push to GitHub. Do NOT update the issue. User will handle that.

## Decision log (quick-reference)

- `rate[30s]` vs `irate[15s]` → **irate[15s]** (per issue)
- Scrape interval → **5s** (already in working tree)
- Prometheus query `step` → **10s**
- CPU unit → **cores** (drop `* 100`)
- Container filter for CPU/mem/disk → `container!="",container!="POD"`
- Network filter → none (only `container=""` rows exist — shared netns)
- Pod→node join → via `instance` label (cAdvisor + node_exporter share it)
- Pod buckets → master / tserver / other (by pod-name prefix)
- Sidecar breakdown → hidden by default (future toggle)
- Chart.js plugins → bundled inline (~100KB, acceptable)
- AWS values.yaml → do not touch
- Test cluster → k3s-virsh (context `k3s-virsh`)
