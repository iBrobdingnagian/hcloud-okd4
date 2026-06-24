# Service mesh & tracing UIs — Istio, Kiali, Jaeger

This covers the mesh/observability-UI tools and the **`appsim-mesh`** showcase that ties
them together. They build on the existing observability stack ([SCANNING.md](SCANNING.md)
covers scanning; [ARCHITECTURE.md](ARCHITECTURE.md) is the big picture).

## What each adds (and the overlaps)

| Tool | Role | Overlap / dependency |
|------|------|----------------------|
| **Istio** | service mesh — injects an Envoy sidecar that produces traffic metrics + traces | the prerequisite for Kiali |
| **Kiali** | service-mesh **console** — live service graph, traffic, health | needs Istio + a sidecar-injected app |
| **Jaeger** | distributed-trace **UI** | reuses the **Tempo** operator's built-in Jaeger UI — no new trace store |
| **OpenSearch + Dashboards** | log search/visualization (Kibana) | a **second** log stack alongside Loki — see SCANNING/observability |

> **Heavy.** Istio puts an Envoy sidecar on every mesh pod; OpenSearch runs a JVM.
> On an already-loaded lab, scale the cluster up first. Everything is best-effort/EXPERIMENTAL.

## Install

```bash
./deploy-okd.sh --devops-components istio,kiali,jaeger
# or pick 23) Jaeger / 25) Istio / 26) Kiali from ./deploy-okd.sh --devops
```

- **Istio** (`install_istio`) — Helm `istio/base` + `istiod` + `istio/cni`, with
  `global.platform=openshift` (OpenShift needs `istio-cni` because the sidecar init can't
  get `NET_ADMIN` under the restricted SCC). The `istio-system`/`istio-cni` SAs get
  `privileged`. Sidecars are injected into namespaces labelled `istio-injection=enabled`.
- **Kiali** (`install_kiali`) — Helm `kiali-server` in `istio-system`, `anonymous` auth,
  wired to **Prometheus** (UWM `thanos-querier`), **tracing** (Tempo/Jaeger query) and the
  monitoring **Grafana**. Route `https://kiali.<apps>`. Self-bootstraps Istio if missing.
- **Jaeger** (`install_jaeger`) — exposes the Jaeger UI the **operator** `TempoStack`
  already runs (`template.queryFrontend.jaegerQuery`). Ensures operator Tempo exists, then
  routes `https://jaeger.<apps>`. (Helm single-binary Tempo has no Jaeger UI — use Grafana's
  Tempo datasource there.) Point app/mesh tracing at `tempo-tempo-distributor.observability.svc:4317`.

## The showcase — `appsim-mesh`

```bash
./deploy-okd.sh --devops-components appsim-mesh    # or menu 27) Sim:Mesh
```

`install_appsim_mesh` runs **Online Boutique inside the mesh**: it creates `appsim-mesh`,
labels it `istio-injection=enabled`, and deploys the 11-service Boutique via ArgoCD so
every pod gets an **Envoy sidecar** (pods become `2/2`). Boutique's built-in **Locust**
load generator drives constant traffic, so the mesh continuously emits metrics and traces.

The same app is then observable four ways:

| See | Where |
|-----|-------|
| live **service graph**, traffic rates, health | **Kiali** — `https://kiali.<apps>` |
| end-to-end **distributed traces** across the 11 services | **Jaeger** — `https://jaeger.<apps>` (and Grafana → Tempo) |
| **logs** | OpenSearch/Kibana (`https://kibana.<apps>`) and Loki (Grafana → Explore) |
| **metrics** (incl. Envoy/istio) | Prometheus/UWM → Grafana |

```bash
oc -n appsim-mesh get pods            # all 2/2 (app container + istio-proxy sidecar)
oc -n appsim-mesh logs deploy/loadgenerator   # Locust RPS feeding the mesh
```

The *existing* simulations also feed these UIs without changes: `appsim-events`/
`appsim-cicd` OTLP traces reach the Tempo/Jaeger UI; Fluent Bit ships all pod logs to
OpenSearch.

## Notes / gotchas
- Istio on OpenShift is version-sensitive (CNI + SCCs). If sidecars don't inject, check
  `oc -n istio-cni get pods` and that the namespace label is set *before* the app rolls out.
- Kiali shows little until there's a sidecar-injected app with traffic — that's what
  `appsim-mesh` provides.
- Jaeger requires the **operator** Tempo path; selecting `jaeger` will install it.
