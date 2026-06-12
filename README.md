![Docker Build](https://github.com/slauger/hcloud-okd4/workflows/Docker%20Build/badge.svg)

# hcloud-okd4

Deploy OKD4 (OpenShift) on Hetzner Cloud using HashiCorp Packer, Terraform, and Ansible.

![OKD4 on Hetzner Cloud](https://raw.githubusercontent.com/slauger/hcloud-okd4/master/okd4-hcloud.png)

---

## Important Notice

Hetzner Cloud does **not** meet the I/O performance and latency requirements for etcd – even when using local SSDs (not Ceph). This may cause issues during the cluster bootstrap phase.

This setup is suitable for small test environments only. Not recommended for production clusters.

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

Grafana ships with three provisioned cluster dashboards (read-only files
generated from `grafana/gen-dashboards.py`; any JSON dropped into
`grafana/dashboards/` is provisioned too):

- **OKD / Cluster Overview** — node/pod/alert counts, cluster CPU/memory/
  disk gauges, per-node usage and network, top pods, API server request
  rate/latency/errors, etcd health (leader, DB size, commit latency), and
  a firing-alerts table.
- **OKD / Nodes** — per-node drill-down (CPU, load, memory, disk I/O,
  network, filesystems) with a node selector.
- **OKD / Workloads** — per-namespace pods, CPU/memory/network by pod,
  restarts, PVC usage.

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
