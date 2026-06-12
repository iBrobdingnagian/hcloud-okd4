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

Notes:
- `--yes` implies `--no-admin` (passwords can't be prompted non-interactively);
  the cluster is left on the `kubeadmin` credentials printed in the summary.
- Auto-destroy scheduling (`--no-autodestroy` to skip) is only wired up on
  macOS (launchd); on Linux, run `./destroy-okd.sh` yourself before the
  estimated lab duration elapses to avoid ongoing Hetzner charges.
- New OpenShift nodes periodically submit fresh serving-cert CSRs; on
  platform "none" nothing approves them automatically. Run `make sign_csr`
  (or repeat step 11 below) until `oc get csr` shows nothing pending.

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
