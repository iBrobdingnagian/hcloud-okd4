![Docker Build](https://github.com/slauger/hcloud-okd4/workflows/Docker%20Build/badge.svg)

# hcloud-okd4

Deploy OKD4 (OpenShift) on Hetzner Cloud using HashiCorp Packer, Terraform, and Ansible.

![OKD4 on Hetzner Cloud](https://raw.githubusercontent.com/slauger/hcloud-okd4/master/okd4-hcloud.png)

---

## Important Notice

Hetzner Cloud does **not** meet the I/O performance and latency requirements for etcd – even when using local SSDs (not Ceph). This may cause issues during the cluster bootstrap phase.

This setup is suitable for small test environments only. Not recommended for production clusters.

---

## Documentation

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — how everything fits together and what every
  component does (start here for the big picture).
- [GETTING_STARTED.md](GETTING_STARTED.md) — first run.
- [APPSIM.md](APPSIM.md) — the real-world application simulations (GitOps, CI/CD, Kafka, AWX).
- [SCANNING.md](SCANNING.md) — image (Harbor/Trivy) + code (SonarQube) scanning.
- [MESH.md](MESH.md) — service mesh & tracing UIs (Istio, Kiali, Jaeger) + the mesh showcase.
- [CICD.md](CICD.md) — the appsim-cicd CI engines (Jenkins vs GitLab CI).
- [AFFINITY.md](AFFINITY.md) — scheduling: affinity/anti-affinity and draining nodes.

---

## Automated Deploy / Destroy

`deploy-okd.sh` and `destroy-okd.sh` wrap the whole Quick Start procedure below
(plus the live region/pricing checks, CSR approval, and DNS-cache fixes
discovered while running this on Hetzner) into two scripts:

```bash
cp .env.example .env   # fill in HCLOUD_TOKEN, CLOUDFLARE_*, TF_VAR_dns_domain, TF_VAR_dns_zone_id
./deploy-okd.sh --yes        # non-interactive: 3 masters/3 workers, cheapest types, current region, 8h
./destroy-okd.sh --yes       # tear down all terraform-managed resources
```

Run `./deploy-okd.sh --help` for all options (region, master/worker counts and
types, OKD release, lab duration, etc.). Without `--yes` both scripts walk you
through interactive prompts (region picker, live pricing, version selection,
htpasswd admin creation).

### Deployment profiles

When run interactively without `--masters`/`--workers`/`--master-type`/
`--worker-type`, `deploy-okd.sh` first asks which deployment profile to use
(or pass `--profile N` to skip the menu):

1. **Production - Best Servers** — 3 masters / 3 workers on dedicated CCX
   types (>=8 vCPU / 32 GB for masters, >=4 vCPU / 16 GB for workers).
2. **Production - Cost Optimized** — 3 masters / 3 workers on the cheapest
   qualifying types in the chosen region. This is also what `--yes` uses by
   default.
3. **Lab** — choose a topology (`--lab-topology`: `1x0`, `1x1`, `1x2`, `1x3`
   or `3x3`, masters x workers) and a cost tier (`--lab-tier`: `low` =
   cheapest qualifying, `mid` = mid-range, `high` = dedicated CCX types).
   `1x0` is a single schedulable master with no separate workers.
4. **Manual** — the original interactive picker (region, counts, types).
   Selected automatically if you pass `--masters`/`--workers`/
   `--master-type`/`--worker-type` directly.

### Adaptive scaling

If `deploy-okd.sh` finds an existing cluster for `TF_VAR_dns_domain` already
running in Hetzner, it offers to **scale** it instead of refusing to proceed:
pass `--scale` (with `--masters`/`--workers` for the new *total* counts, or
answer the prompts) to add or remove nodes on a live cluster.

- **Workers**: scaling up runs `terraform apply` to create the new VM(s) and
  approves their CSRs until they're `Ready`. Scaling down cordons/drains the
  highest-numbered worker(s), deletes their Node objects, then runs
  `terraform apply` to destroy the VM(s).
- **Masters**: supported the same way, but is **experimental** — etcd
  membership is not guaranteed to reconcile automatically on platform "none".
  Scaling down additionally removes the member via `etcdctl member remove`
  before the VM is destroyed. Even master counts are rejected (etcd quorum).
  After scaling masters, check `oc get etcd -o jsonpath='{.status.conditions}'`
  and `oc -n openshift-etcd get pods`.

#### Load-driven autoscaling (`--autoscale`)

This cluster is `platform: none`, so OpenShift's native **MachineSets /
MachineAutoscaler / ClusterAutoscaler don't work** — there is no Hetzner
machine-api actuator, and `MachineSet` objects never reconcile into real
servers (that's exactly why nodes are created with Terraform and joined via
CSR approval). The *Compute → Machines / MachineSets / MachineAutoscalers*
entries in the web console are therefore always empty here.

`./deploy-okd.sh --autoscale` re-creates the **behavior** of a MachineAutoscaler
on top of the existing scaling path: it runs a foreground watch loop (Ctrl-C to
stop) that polls the cluster and, **workers only**:

- **scales up** (adds one worker) when a pod is `Pending`/`Unschedulable`
  because of `Insufficient cpu`/`memory` — i.e. load that more identical
  workers can actually fix (taint/affinity/nodeSelector mismatches are ignored);
- **scales down** (removes one worker) when current pod requests would still
  fit under a utilisation threshold on one fewer worker, held for several
  consecutive polls to avoid flapping;
- never shrinks while any pod is stuck unschedulable, and stays within
  `--autoscale-min`/`--autoscale-max` (defaults: current count … current + 2).

Each action goes through the same Terraform + drain + CSR path as a manual
`--scale`, so it is just as safe. Flags: `--autoscale-min N`,
`--autoscale-max N`, `--autoscale-interval S` (seconds, default 60, min 15).

```bash
# add load in another terminal, e.g. a Deployment with big CPU requests / many
# replicas, then watch workers grow up to the max and shrink back when idle:
./deploy-okd.sh --autoscale --autoscale-min 1 --autoscale-max 4 --autoscale-interval 30
```

#### Resident Cluster Autoscaler — Hetzner cloud provider (`--cluster-autoscaler`)

If you want a **resident, in-cluster** autoscaler (not a foreground loop), deploy
the upstream **Kubernetes Cluster Autoscaler with the native Hetzner cloud
provider**, which calls the Hetzner API directly to create/delete servers in a
node pool. (OpenShift's `MachineAutoscaler` still can't be used here — it needs
MachineSets, which `platform: none` doesn't have — but the *upstream*
cluster-autoscaler has a `hetzner` provider that bypasses the Machine API.)

```bash
./deploy-okd.sh --cluster-autoscaler --ca-type cx43 --ca-min 0 --ca-max 3
```

What it installs (namespace `cluster-autoscaler`):
- the `cluster-autoscaler --cloud-provider=hetzner` Deployment, with a node pool
  `--nodes=<min>:<max>:<type>:<region>:autoscaled`. New servers boot
  **`ignition/worker.ign`** (base64'd into `HCLOUD_CLOUD_INIT`), the cluster's
  **FCOS snapshot** (`HCLOUD_IMAGE`), the **network** (`HCLOUD_NETWORK`), the
  `…-base` **firewall** and the project **SSH key**;
- a small **CSR auto-approver** Deployment — required because `platform: none`
  won't auto-approve CSRs for nodes with no backing Machine, so unattended
  nodes would otherwise never reach `Ready`.

Notes & caveats (EXPERIMENTAL):
- `--ca-type` defaults to the **current worker type** (`TF_VAR_server_type_worker`)
  so autoscaled nodes match the cluster; `--ca-min`/`--ca-max` default `0`/`3`.
- All cluster-scoped objects are prefixed `hcloud-` to avoid colliding with
  OpenShift's CVO-managed `cluster-autoscaler` ClusterRole/Binding.
- The image is pinned to **v1.30.3**: the Hetzner provider in 1.29.x / 1.30.0 /
  1.31.0 hardcodes an internal draining pool with the retired `cx11` type, which
  breaks every cycle; 1.30.3 / 1.31.1 / 1.32+ remove it.
- Only one firewall can be attached via `HCLOUD_FIREWALL` (the `…-base` one);
  autoscaled nodes are **not** managed by Terraform. Watch it with
  `oc -n cluster-autoscaler logs deploy/cluster-autoscaler -f`.
- **Node naming:** the autoscaler mints servers as `<pool>-<randomhex>` from a
  single shared cloud-init, so it can't do sequential `workerNN` names (that's
  the Terraform `--scale` path). The pool is named `worker-asc` and the
  cloud-init injects a hostname unit that reads the Hetzner metadata server name
  before kubelet starts, so nodes register as
  **`worker-asc-<id>.<domain>`** (e.g. `worker-asc-2d77a23c….okd4.myhelpdesk.gr`)
  instead of Hetzner's default rDNS `static.<ip>…` name.
- **Prove it:** `./deploy-okd.sh --ca-smoke-test` creates a throwaway Pending
  workload so a real node is provisioned via the Hetzner API and joins, then
  deletes it (the node scales back down after the cooldown).

### Monitoring, alerting & Grafana

`deploy-okd.sh` can configure the OKD monitoring stack beyond its defaults:
it enables **user-workload monitoring** (Prometheus/Thanos for your own
projects, in addition to the platform metrics), sets Prometheus retention,
optionally routes warning/critical alerts to a webhook
(`--alert-webhook <URL>`, e.g. a Slack/Teams incoming webhook), and deploys
**Grafana** for visualization (OKD 4.16 no longer bundles it). Grafana runs
in its own `grafana` namespace with a pre-provisioned datasource pointing at
the cluster's Thanos querier — so dashboards can query both platform and
user-workload metrics — and is exposed at `https://grafana.apps.<domain>`
(admin credentials are printed when it's installed and kept in the
`grafana-admin` secret).

Because the extra stack is too heavy for minimal lab nodes, the option is
**only available when at least one schedulable node has more than 12 GB
RAM** — otherwise it is hidden from the menus and skipped with a warning.

It can be installed at either point:
- **During a deploy** — answer `y` at the "Configure monitoring & alerting?"
  prompt after the cluster is up, or pass `--monitoring` (works with `--yes`).
- **On a running cluster** — re-run `./deploy-okd.sh`: when an existing
  cluster is detected, pick "Monitoring" from the menu, or run
  `./deploy-okd.sh --monitoring --yes` non-interactively.

Grafana ships with 11 provisioned dashboards organised into folders
(read-only files generated from `grafana/gen-dashboards.py`; any JSON
dropped into a `grafana/dashboards/<category>/` directory is provisioned
into the matching folder):

- **Cluster** — *Cluster Overview* (nodes/pods/alerts, CPU/mem/disk gauges,
  per-node usage, top pods), *Cluster Capacity* (requests/limits vs
  allocatable, pods per node), *Cluster Alerts* (firing/pending by
  severity and namespace, alert tables).
- **Control Plane** — *API Server & etcd* (request rate/latency/5xx,
  in-flight, etcd leader/proposals/DB size/commit+fsync latency).
- **Nodes** — *All Nodes*, *Masters*, *Workers* (CPU, load, memory, disk
  I/O, network, filesystems, with a node selector).
- **Workloads** — *Workloads by Namespace* (CPU/mem/network/restarts by
  pod), *Pods Health* (not-ready/pending/OOMKilled, waiting reasons, top
  restarters).
- **Network** — ingress/egress, per-node throughput and drops, top pods by
  traffic, TCP retransmits, conntrack usage.
- **Storage** — disk throughput/IOPS/saturation, filesystem and inode
  usage, PVC usage.
- **ONZACK** — two community dashboards (*Cluster Monitoring* and *Namespace
  Monitoring*) from [onzack/grafana-dashboards](https://github.com/onzack/grafana-dashboards),
  vendored under `grafana/vendor/onzack/`. The *without-recording-rules*
  variants are used: they run their queries inline against the Thanos querier
  (which federates platform + user-workload metrics), so they need no extra
  `PrometheusRule`. The upstream recording-rules variant cannot populate on
  OKD's split monitoring stack (custom rules are evaluated by the
  user-workload Prometheus, which never scrapes node-exporter/kube-state-metrics);
  the rules are kept under `grafana/vendor/onzack/rules/` for reference only.
  Because `gen-dashboards.py` regenerates (and wipes) `grafana/dashboards/`,
  vendored third-party dashboards live outside that tree.

Once enabled, metrics and alerts are in the web console under **Observe**,
and Grafana is at `https://grafana.apps.<domain>` (you can also import any
dashboard from grafana.com against the "OpenShift Prometheus" datasource).

Notes:
- `--yes` implies `--no-admin` (passwords can't be prompted non-interactively);
  the cluster is left on the `kubeadmin` credentials printed in the summary.
- Auto-destroy scheduling (`--no-autodestroy` to skip, `--autodestroy-at` to
  pick a different time than `--duration`) is wired up on macOS (launchd) and
  Linux (a `systemd --user` timer, falling back to `at` if `systemd-run` is
  unavailable). On Linux, `systemd --user` timers only fire while you're
  logged in unless you run `sudo loginctl enable-linger $USER`. A manual
  `./destroy-okd.sh` cancels any pending auto-destroy.
- New OpenShift nodes periodically submit fresh serving-cert CSRs; on
  platform "none" nothing approves them automatically. Run `make sign_csr`
  (or repeat step 11 below) until `oc get csr` shows nothing pending.
- On Linux hosts with k3s installed, `/usr/local/bin/oc` is often a symlink
  to k3s, which shadows the real OpenShift CLI and causes errors like
  `error: No help topic for 'login'`. `deploy-okd.sh` detects this and, if
  the real `oc` is installed under `~/.local/bin`, fixes `PATH` for the
  current run and persists the fix to `~/.bashrc` and `~/.zshrc` (open a new
  shell, or `exec $SHELL`, for it to take effect there).

---

### DevOps tooling (`--devops`)

`deploy-okd.sh` can install CI/CD & GitOps tooling on the running cluster —
interactively (a prompt after the cluster is up, or the "DevOps" entry in the
existing-cluster menu) or non-interactively with `--devops` /
`--devops-components argocd,jenkins,gitlab,harbor,artifactory,awx`. Where an
OperatorHub operator exists in the cluster's catalog it is used; otherwise the
component is installed with Helm or run as a plain Deployment.

| Component | How it's installed | Login |
|-----------|--------------------|-------|
| **cert-manager** | `cert-manager` Subscription (channel `stable`, into `openshift-operators`) + a self-signed `ClusterIssuer` | n/a (cluster service) |
| **ArgoCD** | `argocd-operator` Subscription (channel `alpha`, into `openshift-operators` — it only supports AllNamespaces) + an `ArgoCD` CR that enables a reencrypt Route | `admin` / secret `argocd-cluster` (printed in the summary) |
| **Jenkins** | the OpenShift Jenkins image run as a plain Deployment (no Jenkins operator in the catalog; the bundled DeploymentConfig template is deprecated/unreliable on 4.16) | **your OpenShift account** — the image's OAuth login plugin (`OPENSHIFT_ENABLE_OAUTH`) + the SA's `oauth-redirectreference` |
| **GitLab** | `gitlab-operator-kubernetes` Subscription (channel `stable`, own-namespace — it only supports OwnNamespace) + a `GitLab` CR | `root` / secret `gitlab-gitlab-initial-root-password` |
| **Harbor** | Helm chart `goharbor/harbor` (no usable operator in the catalog), `expose.type=clusterIP` behind an OpenShift edge Route, PVCs on the default storageclass | **your OpenShift account** via a bundled **Dex** OIDC bridge (`auth_mode=oidc_auth`), *and* a local `admin` (random password, in the summary) |
| **JFrog Artifactory OSS** | Helm chart `jfrog/artifactory-oss` (no operator), bundled nginx disabled in favour of an OpenShift edge Route, PVCs on the default storageclass | local `admin` only — **OSS has no SSO and no Docker/OCI registry** (both are Pro features) |
| **AWX** (Ansible Automation Platform) | Helm chart `awx-operator/awx-operator` with `AWX.enabled=true` (deploys the operator *and* an AWX instance); `ingress_type=route` so the operator publishes an edge Route; managed postgres PVC on the default storageclass | `admin` / secret `awx-admin-password` (printed in the summary) |

**Version policy (`--version-policy`, default `n-2`):** operators are pinned
**two releases behind the channel head** for stability, not the bleeding edge.
The Subscription gets `startingCSV: <N-2>` and `installPlanApproval: Manual`
(Manual is what *keeps* it on N-2 — OLM won't silently auto-upgrade past it;
the initial install plan is approved automatically). N-2 is computed live from
the package's channel entries (e.g. cert-manager head `v1.16.5` → pins
`v1.15.2`; argocd head `v0.18.0` → pins `v0.16.0`). Pass `--version-policy
latest` to track the channel head instead (no pin, automatic upgrades). This
applies to the OperatorHub operators (cert-manager, ArgoCD, GitLab) **and the
Helm charts** (Harbor, Artifactory — the 3rd-newest chart version is picked);
the Jenkins/Grafana/Dex images and the storage-provisioner manifests are pinned
to known-good versions in the scripts. OLM does not downgrade in place, so for
operators the policy takes effect on a *fresh* install.

Notes & caveats:
- Each installer is **failure-isolated** — one failing doesn't abort the
  others — and its URL/credentials are appended to the deploy summary.
- **GitLab is experimental and heavy** (gitaly, postgres, redis, minio,
  webservice, sidekiq, its own nginx-ingress). It needs a storageclass, but
  `platform: none` ships none, so selecting GitLab first installs
  **local-path-provisioner** (lab-grade, local-dir backed) and marks it the
  default storageclass. There is no cert-manager on the cluster, so the
  `GitLab` CR disables it (`certmanager.install: false`). GitLab reconciles
  asynchronously — watch `oc -n gitlab-system get gitlab,pods`.
- **Harbor, JFrog & AWX are Helm-installed and experimental**, and need `helm`
  on the host plus a default storageclass (auto-provisioned like GitLab).
  Harbor's random-UID problem is handled by granting `anyuid` to the namespace's
  service accounts and stripping the chart's `seccompProfile` (which `anyuid`
  doesn't permit) while keeping the rest of its container hardening.
- **AWX** installs the community `awx-operator` Helm chart with
  `AWX.enabled=true`, so it deploys both the operator and an AWX instance; it
  reconciles asynchronously — watch `oc -n awx get awx,pods,route`. Login is
  `admin` / secret `awx-admin-password`. It is **not** the Red Hat Ansible
  Automation Platform product (that needs a subscription); this is upstream AWX.
- **Harbor SSO uses a Dex bridge.** OpenShift's built-in OAuth server is OAuth2,
  *not* a compliant OIDC provider (no `/.well-known/openid-configuration`), so a
  tiny **Dex** instance (in the `dex` namespace, `openshift` connector → cluster
  OAuth) is deployed to expose real OIDC discovery, and Harbor's
  `auth_mode=oidc_auth` is pointed at it. If Dex doesn't come up, Harbor still
  works with its local `admin`.
- **JFrog OSS** is registry-less and SSO-less by design (those are Pro
  features); pick it only for Maven/npm/PyPI-style repositories with a local
  admin. For an SSO-capable OCI registry, **Harbor** is the better fit here.
- `--yes` installs only cert-manager + ArgoCD + Jenkins (GitLab, Harbor, JFrog
  and AWX are opt-in — they're heavier and want persistent storage).

---

## Architecture

By default, a single-node cluster is deployed with the following components:

| Component     | Type / Size |
|---------------|-------------|
| Master Node   | cpx41       |
| Load Balancer | lb11        |
| Bootstrap Node| cpx41 (removed after bootstrap) |
| Ignition Node | cpx21 (removed after bootstrap) |

Server types and the Hetzner network zone are all configurable via Terraform
variables (set in `.env`, see `.env.example`):

```bash
export TF_VAR_replicas_worker=3       # additional worker nodes
export TF_VAR_server_type_master=cpx41
export TF_VAR_server_type_worker=cpx41
export TF_VAR_server_type_bootstrap=cpx41
export TF_VAR_server_type_ignition=cpx21
export TF_VAR_network_zone=eu-central # must match TF_VAR_location's region
export TF_VAR_fcos_release=           # pin to a specific CoreOS snapshot, or leave empty for most recent
```

---

## Version & Deployment Options

You can set the desired release version with the `OPENSHIFT_RELEASE` environment variable.

Example:

```bash
export DEPLOYMENT_TYPE=okd # Options: "okd" or "ocp", default is "okd"
export OPENSHIFT_RELEASE=$(make latest_version) # or a fixed version like "4.19.9"
```

For OCP (Red Hat OpenShift), you will also need a valid pull secret, available from cloud.redhat.com.

---

## Quick Start

1. Build and start the toolbox
   ```bash
   make fetch
   make build
   make run
   ```
2. Create `install-config.yaml` (see example in *Configuration*)
3. Generate manifests
   ```bash
   make generate_manifests
   ```
4. Generate ignition configs
   ```bash
   make generate_ignition
   ```
5. Export required environment variables (see example in *Configuration*)
6. Build Fedora/RedHat CoreOS image using Packer
   ```bash
   make hcloud_image
   ```
   Set `PACKER_LOCATION`/`PACKER_SERVER_TYPE` to control where the temporary
   build server runs (defaults: `nbg1` / `cx33`). The image URL is read from
   `openshift-install coreos print-stream-json`; current FCOS streams only
   publish a `qcow2.xz` artifact (no `qcow2.gz`), and the packer provisioner
   decompresses with `xz`.
7. Deploy infrastructure with Terraform (including bootstrap and ignition node)
   ```bash
   make infrastructure BOOTSTRAP=true
   ```
8. Wait for bootstrap completion
   ```bash
   make wait_bootstrap
   ```
9. Remove bootstrap and ignition node
   ```bash
   make infrastructure
   ```
10. Wait for installation to finish
    ```bash
    make wait_completion
    ```
11. Approve worker CSRs (if workers are deployed)
    ```bash
    make sign_csr
    sleep 60
    make sign_csr
    ```
---

## Configuration

### Example: install-config.yaml

```yaml
apiVersion: v1
baseDomain: 'example.com'
metadata:
  name: 'okd4'
compute:
  - hyperthreading: Enabled
    name: worker
    replicas: 0
controlPlane:
  hyperthreading: Enabled
  name: master
  replicas: 1
networking:
  clusterNetworks:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.30.0.0/16
machineCIDR: platform:
  none: {}
pullSecret: '{"auths":{"none":{"auth":"none"}}}'
sshKey: ssh-rsa AAAA…<your ssh key here>
```

### Required Environment Variables

```bash
# Terraform / DNS
export TF_VAR_dns_domain=okd4.example.com
export TF_VAR_dns_zone_id=YOUR_ZONE_ID

# Hetzner Cloud credentials
export HCLOUD_TOKEN=YOUR_HCLOUD_TOKEN

# Cloudflare credentials
export CLOUDFLARE_EMAIL=user@example.com
export CLOUDFLARE_API_KEY=YOUR_API_KEY
```

---

## Firewall & Access

- Nodes are **not directly exposed to the internet** by default.
- Only the load balancer is public accessible.
- SSH access to nodes will only be possible with additional firewall configuration.

---

## Deploying OCP (Red Hat OpenShift)

To deploy OCP instead of OKD:

```bash
export DEPLOYMENT_TYPE=ocp
export OPENSHIFT_RELEASE=4.19.9 # example version
make fetch build run
```

You can also choose the latest version from a specific channel:

```bash
export OCP_RELEASE_CHANNEL=stable-4.19
export OPENSHIFT_RELEASE=$(make latest_version)
make fetch build run
```

---

## Limitations / Not for Production

- I/O performance and latency issues with etcd (see above).
- Components that rely on strong consistency (like etcd) may suffer under heavy load.
- No stability guarantees for large clusters or production use.

---

## Author

[slauger](https://github.com/slauger)
