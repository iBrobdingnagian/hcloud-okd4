# ONZACK community dashboards (vendored)

Two Kubernetes/OpenShift dashboards from
**https://github.com/onzack/grafana-dashboards** (created by ONZACK with LGT
Bank, released to the community). Kept here, *outside* `grafana/dashboards/`,
because `grafana/gen-dashboards.py` deletes and regenerates that tree — vendored
third-party files would be wiped. `functions/monitoring.sh` mounts this folder
into Grafana as the **ONZACK** folder.

## What's included

| File | Grafana dashboard | UID |
|------|-------------------|-----|
| `onzack-cluster-monitoring.json`   | Cluster Monitoring   | `ozk-std-clstr-mon-norec` |
| `onzack-namespace-monitoring.json` | Namespace Monitoring | `ozk-std-ns-mon-norec` |

Both bind to a `${datasource}` template variable (type *datasource*), so they
auto-select our default **OpenShift Prometheus** datasource (thanos-querier).
No editing needed.

## Why the *without-recording-rules* variant (and not the rules)

ONZACK ships each dashboard in two flavours:

- **with-recording-rules** — panels query short recorded series (e.g.
  `node_cpu_seconds_total:sum_rate5m`) that a set of Prometheus *recording
  rules* must precompute.
- **without-recording-rules** — panels run the full queries inline. **This is
  what we vendor here.**

On OKD the monitoring stack is **split**: platform metrics (node-exporter,
kube-state-metrics, cAdvisor) live in the *platform* Prometheus
(`openshift-monitoring`), while any custom `PrometheusRule` you create is
evaluated by the *user-workload* Prometheus — which never scrapes those
targets. So the recording-rules variant would record **empty** series and the
panels would be blank. The recording-rules approach assumes a single
all-seeing Prometheus (e.g. `kube-prometheus-stack`), not OKD's split stack.

Our Grafana datasource points at **thanos-querier**, which federates *both*
the platform and user-workload metrics. The without-recording-rules dashboards
therefore have every raw metric they need and render with no extra setup.

## `rules/` — kept for reference only (NOT applied)

The original ONZACK recording rules are kept under `rules/` for anyone running
a single-Prometheus stack. They are **intentionally not applied** by
`deploy-okd.sh` for the reason above. If you ever move to
`kube-prometheus-stack`, apply them with `oc apply -f rules/` and switch to the
upstream `with-recording-rules` dashboards.

Upstream license: see `LICENSE` in this directory.
