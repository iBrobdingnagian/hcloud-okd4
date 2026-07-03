# Service mesh & tracing UIs — Istio, Kiali, Jaeger

This covers the mesh/observability-UI tools and the mesh **app showcases** that tie them
together. They build on the existing observability stack ([SCANNING.md](SCANNING.md)
covers scanning; [ARCHITECTURE.md](ARCHITECTURE.md) is the big picture).

## What each adds (and the overlaps)

| Tool | Role | Overlap / dependency |
|------|------|----------------------|
| **Istio** | service mesh — injects an Envoy sidecar that produces traffic metrics + traces | the prerequisite for Kiali |
| **Kiali** | service-mesh **console** — live service graph, traffic, health | needs Istio + a sidecar-injected app **+ UWM metrics** |
| **Jaeger** | distributed-trace **UI** | reuses the **Tempo** operator's built-in Jaeger UI — no new trace store |
| **OpenSearch + Dashboards** | log search/visualization (Kibana) | a **second** log stack alongside Loki — see SCANNING/observability |

> **Heavy.** Istio puts an Envoy sidecar on every mesh pod; OpenSearch runs a JVM.
> Everything is best-effort/EXPERIMENTAL.

## Install

```bash
./deploy-okd.sh --devops-components istio,kiali,jaeger
# or pick 23) Jaeger / 25) Istio / 26) Kiali from ./deploy-okd.sh --devops
```

- **Istio** (`install_istio`) — Helm `istio/base` + `istiod` + `istio/cni`.
  - OpenShift needs **`istio-cni`** (the sidecar init can't get `NET_ADMIN` under the
    restricted SCC). The CNI is installed with `global.platform=openshift` **plus** the
    Multus paths (`cni.cniConfDir=/etc/cni/multus/net.d`, `cni.cniBinDir=/var/lib/cni/bin`,
    `cni.chained=false`) so it registers a `istio-cni` `NetworkAttachmentDefinition`.
    ⚠️ **Do not** pass `--set profile=openshift` — that chart has no such profile and the
    CNI install aborts, leaving injected pods stuck in `Init` (no NAD).
  - `meshConfig.defaultConfig.holdApplicationUntilProxyStarts=true` so app containers wait
    for the Envoy sidecar (fewer startup-race crash-loops).
  - A **tracing** OpenTelemetry provider (`tempo-otlp`) + a mesh-wide `Telemetry` point
    sidecar spans at `tempo-tempo-distributor.observability.svc:4317`
    (`MESH_TRACING_OTLP_SERVICE` overrides). See **Known issues** below.
  - An `istiod` ServiceMonitor scrapes control-plane metrics into UWM.
- **Kiali** (`install_kiali`) — Helm `kiali-server` in `istio-system`, `anonymous` auth.
  For the **graph to actually populate** the installer now also:
  - enables **User Workload Monitoring** and wires Kiali's Prometheus to the UWM
    `thanos-querier` with **bearer auth** (`use_kiali_token`, `insecure_skip_verify`) +
    grants the Kiali SA `cluster-monitoring-view` (else `x509: unknown authority`);
  - creates a **PodMonitor** (`_mesh_metrics`) in each mesh namespace so the Envoy sidecar
    metrics (`istio_requests_total`) reach UWM;
  - exposes a **reencrypt** route to port **20001** (Kiali serves HTTPS there; an edge
    route to `http` yields a 503/400 "Application is not available").
  - Route `https://kiali.<apps>`; also wired to tracing (Tempo/Jaeger) and Grafana.
- **Jaeger** (`install_jaeger`) — exposes the Jaeger UI the **operator** `TempoStack`
  already runs. Ensures operator Tempo (S3 = in-cluster MinIO), then routes
  `https://jaeger.<apps>`. (Helm single-binary Tempo has no Jaeger UI.)

## Mesh app showcases (sidecar-injected, with traffic)

Each creates its namespace, labels it `istio-injection=enabled`, grants `anyuid`, adds the
sidecar **PodMonitor**, and drives traffic so Kiali/Jaeger have live data.

| Menu | Token | App | Source | Traffic |
|---|---|---|---|---|
| 27 | `appsim-mesh` | Google **Online Boutique** (11 svcs) via ArgoCD | GoogleCloudPlatform/microservices-demo | built-in Locust |
| 28 | `appsim-bookinfo` | Istio **Bookinfo** (productpage → details/reviews/ratings) | istio/istio (GitHub) | in-mesh `traffic-gen` curl loop |
| 29 | `appsim-emojivoto` | Buoyant **emojivoto** (web → emoji/voting) | BuoyantIO/emojivoto (`run.linkerd.io/emojivoto.yml`) | built-in `vote-bot` |

```bash
./deploy-okd.sh --devops-components appsim-mesh,appsim-bookinfo,appsim-emojivoto
oc -n bookinfo  get pods         # all 2/2 (app + istio-proxy)
oc -n emojivoto get pods         # all 2/2; vote-bot drives traffic
```

Override the source manifests with `BOOKINFO_MANIFEST` / `EMOJIVOTO_MANIFEST`.

The same apps are then observable:

| See | Where |
|-----|-------|
| live **service graph**, traffic rates, health | **Kiali** — `https://kiali.<apps>` → Graph → pick the namespace |
| **distributed traces** | **Jaeger** — `https://jaeger.<apps>` (see Known issues) |
| **logs** | OpenSearch/Kibana and Loki (Grafana → Explore) |
| **metrics** (incl. Envoy/istio) | Prometheus/UWM → Grafana |

## Getting Envoy sidecars into your own app

```bash
oc label ns <ns> istio-injection=enabled --overwrite      # BEFORE the app rolls out
oc adm policy add-scc-to-group anyuid system:serviceaccounts:<ns>
oc -n <ns> rollout restart deploy                          # inject sidecars (not retroactive)
oc -n <ns> get pods                                        # READY 2/2 = injected
```

Then generate traffic (Kiali graphs *active* traffic only) and open Kiali → Graph.

## Known issues / gotchas
- **istio-cni NAD:** if injected pods hang in `Init` with
  `cannot find a network-attachment-definition (istio-cni)`, the CNI didn't install —
  check `oc -n istio-cni get pods` and that `profile=openshift` was **not** used.
- **Distributed traces may not appear in Jaeger on Istio 1.30.** All the plumbing is in
  place (Tempo up, provider + `Telemetry`, sidecars carry the tracer with a healthy path to
  Tempo on OTLP :4317 / Zipkin :9411), but istiod 1.30.2 has been observed **not attaching
  the `Telemetry` tracing to the sidecar HTTP listeners** (no `random_sampling` in the Envoy
  config → no spans). The **Kiali graph works regardless** (it uses metrics, not traces).
  Workarounds to try: a different Istio minor, or the legacy `meshConfig.defaultConfig.tracing.zipkin`
  path pointing at `tempo-tempo-distributor.observability.svc:9411`.
- **Heavy Boutique services can crash-loop under an overcommitted worker.** `emailservice`/
  `recommendationservice` may fail their `:15020/app-health` probes (`context deadline
  exceeded`) and restart when the node is CPU-throttled. `holdApplicationUntilProxyStarts`
  helps the proxy race but not raw CPU starvation — give them more CPU or use the lighter
  `appsim-bookinfo`/`appsim-emojivoto` demos.
- Kiali shows little until there's a sidecar-injected app **with traffic** — that's what the
  showcases provide.
