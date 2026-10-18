# OKD and Red Hat OpenShift deployment lifecycle

The same scripts support both distributions. Distribution selects the installer,
OS image, pull-secret requirements and workspace; the established deployment
profile, region, live availability and pricing flow is shared.

## Configure a workspace

Copy the appropriate example:

```bash
# Red Hat OpenShift
cp clusters/openshift.yaml.example clusters/openshift.yaml
# Additional independent OKD deployment
cp clusters/dev.yaml.example clusters/okd-lab2.yaml
```

Edit `name` to match the filename without `.yaml`. Set `distribution: openshift`
or `distribution: okd`, a unique cluster domain and Cloudflare zone, desired
release, region/network zone and non-overlapping machine/node/load-balancer
network ranges. Use the template's other required fields. Workspace names do
not select the distribution: the YAML field does.

Set `credentials_file` to a private file containing `HCLOUD_TOKEN` and
`CLOUDFLARE_API_TOKEN`. Supply the configured private SSH key and its `.pub`
companion. For Red Hat also set `pull_secret_file` to private pull-secret JSON
from [Red Hat](https://console.redhat.com/openshift/install/pull-secret).
`.env`, `.secrets/`, `.work/`, `.cluster-snapshots/`, Terraform state and logs are
ignored by Git. The local `clusters/openshift.yaml` is also ignored; the
committed `.example` is the portable template. Do not embed credentials in
manifests or commit generated install configuration.

Named clusters use `.work/NAME/` with their own environment, Terraform state,
installation artifacts, logs and snapshots. The root environment belongs to the
legacy OKD workspace; changing branches does not create an independent cluster.
Never change an existing cluster's distribution/domain to create another one.

## Choose releases

Named manifests require a full pinned release. Red Hat uses `4.MINOR.PATCH`;
OKD uses its complete OKD release tag. Review available Red Hat binaries in the
[official mirror](https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/)
and check support/entitlement through Red Hat. Availability does not establish
lifecycle support or certify Hetzner as a supported platform.

The Red Hat release helper can offer newest numeric patches per line for a fresh
legacy installation without a configured version; named workspaces keep their
pinned YAML release. `RH_OPENSHIFT_RELEASE` and `RH_PULL_SECRET_FILE` are legacy
OpenShift defaults, not overrides for named manifests. `RH_OFFLINE_TOKEN` is not
used. Installer/client downloads use official mirror SHA-256 checksums; RHCOS
comes from the installer's embedded stream metadata. The infrastructure remains
`platform: none` UPI. Red Hat subscription costs are separate from the displayed
Hetzner infrastructure estimate.

## Deploy and resume

```bash
./deploy-okd.sh
# Or target an already configured workspace directly:
./deploy-okd.sh --cluster openshift --no-autodestroy
```

Interactive startup selects distribution and workspace before loading its
environment. With multiple matching manifests, select the desired workspace.
Choose deploy/continue or restore. Fresh deploys offer the original profile and
region menus, fetch live capacity/pricing, select suitable types by profile and
show estimated cost before confirmation. Manual offers individual type pickers.
The selected region/network zone is saved for subsequent operations.

A configured incomplete workspace offers resume using its saved release,
region, topology and credentials. Declining leaves it untouched. Explicit resume:

```bash
./deploy-okd.sh --cluster openshift --resume --no-autodestroy
```

Resume rejects explicit topology/release changes and never regenerates saved
identity. Missing ignition/kubeconfig files must be recovered before resuming.
Host API checks use the matching managed load balancer IP with original CA and
API hostname TLS verification, avoiding stale host DNS without disabling TLS.

## Destroy with recovery, inspect, or cancel

```bash
./destroy-okd.sh
# Or skip distribution/workspace selection:
./destroy-okd.sh --cluster openshift
```

The action menu provides:

| Choice | Effect |
|---|---|
| 1 | Cold snapshot current nodes, verify completion/retention, then destroy |
| 2 | Destroy without a new snapshot; existing saved images/bundles remain |
| 3 | List local snapshot sets, then return to menu |
| 4 | Inspect cloud snapshots and recording status, then return to menu |
| 0 / Enter | Cancel without starting teardown |

Teardown still requires typing `yes`. Snapshot failure blocks deletion. Capture
stops the nodes, snapshots disks, enables image deletion protection and disables
node Primary IP auto-delete. Existing unsupported storage/network/autoscaler
conditions block capture. Retained disk images, original Primary IPs and private
local bundles are all dependencies of same-IP restore. They are not interchangeable
with shared CoreOS installation images. Snapshot names begin `OKD` or
`RH OpenShift` according to the deployment.

At the local `config/`/`ignition/` cleanup prompt, choose **n** when retaining the
workspace for rotation. Restore bundles also contain original artifacts, but
should not be your only copy: back them up securely. Do not remove `.work/NAME`,
the manifest, credentials, snapshot bundles or original IPs.

## Rotate between two clusters

Use a different manifest, domain and network ranges for each independent fresh
cluster. Preserve names even when the cluster is destroyed but restorable.
For example, configure `openshift-lab2` separately from `openshift`:

```bash
./destroy-okd.sh --cluster openshift --snapshot-before-destroy
./deploy-okd.sh --cluster openshift-lab2 --no-autodestroy
# Later, save the second cluster and bring back the first:
./destroy-okd.sh --cluster openshift-lab2 --snapshot-before-destroy
./deploy-okd.sh --cluster openshift --snapshot-list
./deploy-okd.sh --cluster openshift --restore-snapshot SAVED_SET_ID --no-autodestroy
```

The same procedure applies to `okd-lab2` with `distribution: okd`. Restore does
not consume the snapshot, so the cycle can repeat. A newly captured set records
new disk state; an older set is an older recovery point. Retained snapshots and
IPv4 resources remain billable while compute is absent.

## Restore dependencies and failure cases

```bash
./deploy-okd.sh --cluster openshift --restore
# Explicit set for scripts or a known selection:
./deploy-okd.sh --cluster openshift --restore-snapshot SAVED_SET_ID --no-autodestroy
```

Restore requests typed confirmation before provisioning. It recreates managed
infrastructure, load balancer and Cloudflare records from recorded settings and
uses the original node addresses and credentials. Existing incompatible live
nodes block restore; only an exact interrupted restore can be retried.

A local set marked `ready` means capture completed at that time. Its images and
IP resources may since have been removed. HTTP 404 for a saved Primary IP blocks
restore before provisioning. Do not edit a manifest to substitute a different
IP: recovery on new addresses is not supported by this procedure. Check the
original project/token and retain images/artifacts for recovery investigation.
The cause of the observed legacy OKD IP loss was not established. The user
subsequently authorized removing those unusable OKD image sets; the RH snapshot
and shared installation image were kept.

## Explicit automation

```bash
./destroy-okd.sh --cluster openshift --snapshot-before-destroy --yes
./destroy-okd.sh --cluster openshift --no-snapshot-before-destroy --yes
```

Explicit snapshot-mode flags skip the action menu; without `--yes`, typed teardown
confirmation remains. `--yes` honors an explicit mode or the workspace's recorded
snapshot preference. Scheduled commands use explicit identity and do not prompt.
Use the snapshot flag when a current recovery point is required.

## Validation and work tracking

The 2026-10-18 branch validation passed 118 Python tests, Node manage-page checks
and shell syntax checks. Live OpenShift 4.18.1 single-node verification found one
Ready node and all 34 operators healthy. These checks do not certify every
possible cluster topology or a restore after loss of required IP resources.

| Jira | Scope | State of implementation |
|---|---|---|
| [OPS-162](https://nocservices.atlassian.net/browse/OPS-162) | Distribution-aware deploy, release, profile/region flow and resume/DNS fixes | Implemented |
| [OPS-163](https://nocservices.atlassian.net/browse/OPS-163) | Interactive destroy/restore, snapshot naming and recovery documentation | Implemented |
| [OPS-164](https://nocservices.atlassian.net/browse/OPS-164) | Allocate unused cluster numbers and reserve saved identities | Planned, not implemented |
| [OPS-165](https://nocservices.atlassian.net/browse/OPS-165) | Read-only live restore viability checks and retained-IP lifecycle audit | Planned, not implemented |

Automatic naming is currently manual: choose an unused `okd-labN` or
`openshift-labN` after checking manifests, workspaces, live project resources and
retained sets. A destroyed cluster awaiting restore still occupies its name.
