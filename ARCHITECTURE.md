# Architecture — how it all works together

This document explains **what every component does** and **how they fit together**, from
bare Hetzner Cloud up to a full CI/CD + GitOps + observability + security-scanning
platform. It's the map; the other docs are the detail:

- [README.md](README.md) — deploy/destroy usage, flags, profiles, scaling
- [GETTING_STARTED.md](GETTING_STARTED.md) — first run
- [APPSIM.md](APPSIM.md) — the real-world application simulations
- [SCANNING.md](SCANNING.md) — image (Harbor/Trivy) + code (SonarQube) scanning
- [MESH.md](MESH.md) — service mesh & tracing UIs (Istio, Kiali, Jaeger) + the mesh showcase
- [CICD.md](CICD.md) — the appsim-cicd CI engines (Jenkins vs GitLab CI)
- [AFFINITY.md](AFFINITY.md) — scheduling: affinity/anti-affinity + draining nodes

Everything is driven by **`deploy-okd.sh`**, which sources one file per concern from
`functions/*.sh`. The DevOps tools and app simulations are **opt-in, failure-isolated**
(each `install_*` runs under `|| true` and self-bootstraps its prerequisites), so one
component failing never blocks the rest.

---

## The layers

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Application simulations  (podinfo · Online Boutique · Kafka pipeline ·   │  APPSIM.md
│                            AWX automation · the CI/CD GitOps loop)        │
├─────────────────────────────────────────────────────────────────────────┤
│  DevOps toolchain   ArgoCD · Jenkins · GitLab · Harbor · JFrog · AWX ·    │
│                     Kafka/KRaft/Strimzi · SonarQube · cert-manager · Dex  │
├─────────────────────────────────────────────────────────────────────────┤
│  Observability      metrics (UWM Prometheus/Thanos + Grafana) ·           │
│                     logs (Loki) · traces (Tempo) · pipeline (OTel)        │
├─────────────────────────────────────────────────────────────────────────┤
│  Cluster services   storage (local-path/SMB) · identity (htpasswd, Dex) · │
│                     ingress/routes · image-registry config                │
├─────────────────────────────────────────────────────────────────────────┤
│  OKD 4 control plane + workers   (CoreOS, etcd, kube/OpenShift APIs,      │
│                                   OVN-Kubernetes, OAuth, routers)         │
├─────────────────────────────────────────────────────────────────────────┤
│  Hetzner Cloud (platform "none" / UPI)   servers · network · LB · DNS     │  Terraform
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 1. Platform foundation (bare metal → a running cluster)

`deploy-okd.sh` runs a linear pipeline (`functions/*.sh` in parentheses):

1. **Region & pricing** (`region.sh`, `server-types.sh`, `profiles.sh`) — live Hetzner
   capacity/pricing; pick a profile (Production/Lab/Manual) and instance types.
2. **install-config** (`release.sh`) — choose the OKD release, render
   `install-config.yaml` (platform **`none`** = UPI: we provision the infra ourselves).
3. **Toolbox image** — a container with the matching `openshift-install`/`oc`.
4. **Ignition** — `openshift-install` renders bootstrap/master/worker Ignition + 24h certs.
5. **Infrastructure** (Terraform) — Hetzner **servers** (Fedora CoreOS), **private network**,
   a **load balancer** (api/api-int/ingress), and **DNS** records (Cloudflare).
6. **Bootstrap → masters → workers** — the bootstrap node seeds etcd/control-plane, then is
   removed; workers join via repeated **CSR approval** rounds until all are `Ready`. A
   **watchdog** (`watchdog.sh`) babysits the bootstrap ignition race; **autodestroy**
   (`autodestroy.sh`) schedules a host-side `./destroy-okd.sh` at the lab deadline
   (systemd `--user` timer or `at`).

Day-2 operations: `--scale`/`cluster-scale.sh` (add/remove nodes), `--rescale`/`rescale.sh`
(resize in place), `cluster-autoscaler.sh` (Hetzner-backed autoscaling). Scheduling
control (pin/spread workloads, drain a node) is in **AFFINITY.md**.

> **Platform-"none" consequences** that shape everything above the OS:
> - **No cloud load-balancer integration** → services of type `LoadBalancer` get no
>   external IP; external reach is via OpenShift **Routes** under `*.apps.<domain>`.
> - **No internal image registry** (it's `Removed`, no object storage) → in-cluster image
>   builds use **kaniko** (daemonless), not OpenShift `BuildConfig` Docker strategy.
> - Etcd I/O on Hetzner is marginal → **lab/test use only**.

## 2. Cluster services

- **Storage** (`storage.sh`) — platform `none` ships no storageclass, so
  `ensure_storage_backend` provisions one on demand: **local-path** (node-local, default)
  or **SMB** (Hetzner Storage Box, RWX). Everything needing a PVC (Harbor, GitLab,
  SonarQube, Loki/Tempo/MinIO, Kafka) depends on this.
- **Identity** — an htpasswd **admin** user (`admin.sh`) for console/`oc` login, and
  **Dex** (`install_dex_oidc`) which bridges OpenShift OAuth to OIDC so apps like Harbor
  can do real SSO against the cluster identity.
- **cert-manager** (`install_certmanager`) — certificate automation (a `selfsigned`
  ClusterIssuer by default); other components can request certs from it.

## 3. Observability — see what's happening

Two complementary stacks, both visualized in **one Grafana**:

- **Metrics** (`monitoring.sh`, `--monitoring`) — turns on OpenShift **User-Workload
  Monitoring** (a Prometheus pair + Thanos) and deploys **Grafana** with the
  platform/UWM metrics datasource and a set of dashboards. Gated on a node with >12 GB RAM.
- **Logs & traces** (`observability.sh`) — **Loki** (logs, shipped by **Alloy**),
  **Tempo** (traces), and an **OpenTelemetry Collector** (receives OTLP, fans traces →
  Tempo and metrics → UWM). Each is installable as a lightweight **Helm single-binary**
  or as an **operator** (LokiStack/TempoStack/OpenTelemetryCollector, backed by an
  in-cluster **MinIO** for S3).
- **Glue:** `install_grafana` auto-wires **Loki** and **Tempo** as Grafana datasources
  (and provisions an *Observability* dashboard folder) — regardless of install order — so
  metrics, logs and traces are all in one place. The OTel collector's metrics are scraped
  by UWM via a ServiceMonitor.

Net effect: anything deployed (incl. the app simulations) is observable — metrics on
dashboards, logs in Grafana → Explore → Loki, traces in → Tempo.

## 4. DevOps toolchain (what each tool is for)

Installed via `--devops` (interactive menu) or `--devops-components`. Operators go through
OLM (community catalog), pinned **N-2** by default (`VERSION_POLICY`); the rest are Helm
or plain manifests.

| Component | Role | How it's installed |
|-----------|------|--------------------|
| **cert-manager** | TLS certificate automation | OLM operator |
| **ArgoCD** | **GitOps CD** — reconciles cluster state from Git (the deployer) | argocd-operator |
| **Jenkins** | **CI** — builds/orchestrates pipelines (the builder) | OpenShift Jenkins image + OAuth login |
| **GitLab** | **Git host** — source + the GitOps config repo CI writes to | gitlab-operator (needs `spec.chart.version`) |
| **Harbor** | **container registry** + **Trivy image scanning** (SSO via Dex) | Helm |
| **JFrog Artifactory OSS** | artifact repo (Maven/npm/PyPI; OSS has **no** Docker registry/SSO) | Helm |
| **AWX** | **Ansible automation** — projects, inventories, job templates | awx-operator (Helm) |
| **Kafka + ZooKeeper** | classic event streaming (single broker) | plain manifests |
| **Kafka KRaft** | modern ZooKeeper-less Kafka | plain manifests |
| **Strimzi** | Kafka **operator** — `Kafka`/`KafkaUser`/`KafkaTopic`, mTLS | OLM operator |
| **SonarQube** | **code (SAST) scanning** — bugs, smells, security hotspots | Helm (community edition) |
| **Istio** | **service mesh** — Envoy sidecars (traffic metrics + traces) | Helm (`global.platform=openshift` + istio-cni) |
| **Kiali** | **service-mesh console** — live graph/traffic/health (needs Istio + UWM metrics) | Helm (UWM + reencrypt route) |
| **Jaeger** | **trace UI** — reuses the Tempo-operator Jaeger query UI | route to TempoStack |
| **OpenSearch + Dashboards** | **log search/visualization** (Kibana) + Fluent Bit | Helm (2nd log stack vs Loki) |
| **GitLab Runner** | CI engine for the GitLab-CI variant of `appsim-cicd` | Helm (k8s executor) |

These don't just sit side-by-side — the application simulations wire them into a working
pipeline (next section).

## 5. Application simulations — the tools, working together

`functions/appsim.sh` ([APPSIM.md](APPSIM.md)) exercises the stack the way a real team
would. The headline is **`appsim-cicd`**, the closed CI/CD + GitOps + scanning loop that
connects almost everything:

```
   developer code
        │
        ▼
  ┌───────────┐   SAST    ┌───────────┐  build   ┌──────────────┐  CVE scan  ┌──────────┐
  │ SonarQube │◀──────────│  Jenkins  │─────────▶│ kaniko build │───push────▶│  Harbor  │
  └───────────┘           │ pipeline  │          └──────────────┘            │ + Trivy  │
                          └─────┬─────┘                                       └──────────┘
                                │ bump image tag (git commit)
                                ▼
                          ┌───────────┐    watches    ┌──────────┐   sync    ┌──────────────┐
                          │  GitLab   │──────────────▶│  ArgoCD  │──────────▶│ running app  │
                          │ (config)  │               └──────────┘           │  pod in OKD  │
                          └───────────┘                                       └──────┬───────┘
                                                                                     │ metrics/logs/traces
                                                                                     ▼
                                                                             Grafana / Loki / Tempo
```

1. **Jenkins** runs the pipeline; **SonarQube** scans the source (SAST, report-only).
2. **kaniko** builds the image and pushes to **Harbor**; **Trivy** auto-scans it on push
   (report-only — see [SCANNING.md](SCANNING.md)).
3. The pipeline bumps the image tag in a Helm chart stored in **GitLab**.
4. **ArgoCD** sees the Git change and **syncs** the new version into the cluster.
5. The running app is **observed** via the monitoring/observability stack.

The other simulations isolate individual capabilities: **`appsim-gitops`** (ArgoCD + Helm,
podinfo), **`appsim-boutique`** (a real multi-service app under Locust load),
**`appsim-events`** (a Kafka producer→Streams→consumer pipeline on classic Kafka or
Strimzi mTLS), **`appsim-awx`** (AWX runs an Ansible job).

## 6. End-to-end: the life of a change

Putting the layers together, a single application change flows like this:

1. Code is committed → **Jenkins** pipeline triggers.
2. **SonarQube** analyzes the code (quality/security gate — report-only here).
3. **kaniko** builds a container image → pushed to **Harbor** → **Trivy** scans it for CVEs.
4. Jenkins bumps the deployment's image tag in **GitLab** (the GitOps source of truth).
5. **ArgoCD** detects the commit and reconciles it onto **OKD** (which runs on Hetzner
   infra Terraform built, with storage/identity/ingress from the cluster-services layer).
6. The new pod serves traffic; **Prometheus** scrapes its metrics, **Alloy** ships its
   logs to **Loki**, and OTLP traces land in **Tempo** — all viewable in **Grafana**.
7. Scheduling (where the pod lands, spreading replicas, draining a node for maintenance)
   is controlled with the labels/affinity techniques in **AFFINITY.md**.

That is the whole system: **Terraform/Hetzner** gives you machines, **OKD** turns them
into a cluster, **cluster services** make it usable, the **DevOps toolchain** provides
CI/CD/registry/messaging/automation, **observability** lets you see it, **scanning** keeps
it secure, and the **application simulations** prove it all works together.

---

## Design conventions (true across all components)

- **Opt-in & failure-isolated** — every `install_*` is best-effort (`|| true`) and
  self-bootstraps prerequisites, so partial installs are fine and safe to re-run.
- **Idempotent** — re-running the deploy or any installer converges, doesn't duplicate.
- **N-2 version policy** — operators/charts pin two releases behind head for stability
  (`VERSION_POLICY=latest` to opt out).
- **In-cluster only where it must be** — Kafka (native TCP) and the registries are reached
  in-cluster; UIs/APIs are exposed via edge **Routes** under `*.apps.<domain>`.
- **EXPERIMENTAL/heavy** components (GitLab, SonarQube, Online Boutique, the operator
  observability path) are labelled as such and gated/noted accordingly.
