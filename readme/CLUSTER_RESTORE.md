# Restore an OKD cluster from node snapshots

This runbook restores a previously snapshotted cluster into the same Hetzner
project and domain. It reuses original node disks and Primary IPs, recreates
Terraform-managed networking and load balancing, and updates Cloudflare DNS.
It does not create a new OKD identity or run a fresh installer.

## Prerequisites

- A snapshot set with status `ready` in `./deploy-okd.sh --snapshot-list`.
- The matching `.cluster-snapshots/ID/` directory (or the named cluster's
  `.work/NAME/.cluster-snapshots/ID/`), original SSH key and cluster configuration.
- Valid Hetzner and Cloudflare credentials in the workspace environment file.
- The snapshot images and original node IPv4/IPv6 Primary IPs still present.
- Docker running, the original toolbox image available, and host `oc` and `jq`.
- No original cluster servers still running. Only an exact interrupted restore
  of the same snapshot set can be retried against existing servers.

Snapshot bundles contain installation credentials. Keep them private; never
attach bundles, `.env`, Terraform state, or full unredacted logs to Jira.

## Procedure

1. Enter this repository and inspect the available sets:

   ```bash
   ./deploy-okd.sh --snapshot-list
   ```

2. Restore the selected set with automatic teardown disabled:

   ```bash
   ./deploy-okd.sh --restore-snapshot SNAPSHOT_ID --no-autodestroy
   ```

   Type `restore` when asked. Add `--cluster NAME` to both commands for a named
   cluster. `--yes` skips the prompt for an explicitly authorized unattended run.
   Do not pass new topology, release or region overrides.

3. The procedure validates the snapshot and retained IPs, restores installation
   artifacts and deployment settings, and performs a two-stage Terraform apply:
   nodes first, then firewall, network, load balancer and Cloudflare records.
   A complete snapshot set does not need the original generic CoreOS/Packer image.
   A fresh deployment or additional node without a saved image still needs it.

4. Wait for health verification. Infrastructure creation alone is not a
   successful restore. The API must respond, the expected nodes must be Ready,
   and cluster operators must be Available without Degraded or Progressing.

5. Verify independently:

   ```bash
   export KUBECONFIG="$PWD/ignition/auth/kubeconfig"
   oc --request-timeout=15s get --raw=/readyz
   oc --request-timeout=15s get nodes -o wide
   oc --request-timeout=15s get clusteroperators
   ```

   For a named cluster, use its `.work/NAME/ignition/auth/kubeconfig` instead.
   Compare the recreated load balancer's public address with the Cloudflare
   records for `api`, `api-int`, `apps`, and `*.apps` under the cluster domain.
   Verify `etcd-0` points to the retained control-plane node IP.

## Import existing, unrecorded Hetzner snapshots

Skip import if the set already appears as `ready` in `--snapshot-list`.
For images present in Hetzner without a local snapshot record:

```bash
./deploy-okd.sh --snapshot-cloud-list
./deploy-okd.sh --snapshot-import-template snapshot-import.json
# Edit snapshot-import.json, then validate it without making changes:
./deploy-okd.sh --snapshot-import-plan snapshot-import.json
# After reviewing validation output, record the set (type "import"):
./deploy-okd.sh --snapshot-import snapshot-import.json
./deploy-okd.sh --snapshot-list
# Restore separately, only once the original cluster is gone:
./deploy-okd.sh --restore-snapshot IMPORTED_SET_ID --no-autodestroy
```

Add `--cluster NAME` for named clusters. All relative file paths, including
the review file and paths within it, resolve from the selected workspace:
repository root for legacy, `.work/NAME/` for a named cluster.

The template is intentionally incomplete. Supply:

- `source_state`: original Terraform state from the time the images were taken,
  containing each master/worker server's original ID, type, domain and addresses.
  A state file from a later redeployment has different server IDs and is rejected.
- `config_file`: the original deployment environment file. Only noncredential
  deployment settings are copied into the manifest; current credentials are kept.
- `artifacts_dir`: matching original `ignition/` (including kubeconfig and role
  ignition files), optional `config/`, install configuration and checkpoints.
- `nodes`: every configured node, its own Hetzner snapshot image ID, and both
  retained original IPv4/IPv6 Primary IP resource IDs (not address strings).
- `consistent_shutdown_confirmed` and `matching_artifacts_confirmed`: set to
  `true` only after verifying a consistent cold recovery point and the exact
  original installation identity. Image metadata cannot establish those facts.

The validator requires a complete topology, matching workspace identity/release,
valid role ignition files and selected kubeconfig endpoint, available x86 disk
snapshots whose source server IDs/names match the original state, and unchanged
retained Primary IPs with `auto_delete=false`. IPs assigned to unrelated servers
are rejected. Missing metadata or IPs are not guessed or reallocated.

Discovery, validation and import make only read requests to Hetzner. Import
copies the reviewed local artifacts into a new `import-…` set and records image
provenance without changing cloud labels or protection. Existing local sets are
never overwritten; an incomplete copy is marked failed and cannot be restored.
Restore rechecks image provenance and IP availability before any infrastructure
creation. It still refuses an already-running cluster. Import can record a set
while its matching cluster is running, but does not stop or replace that cluster.
Attached volumes, private node networks and external storage require their own
recovery process; do not attest to a node-disk-only recovery if they are required.

## Recovery and limits

- If Terraform or the health check fails, inspect the cause and retry the same
  restore command. Do not delete Terraform state or switch to a fresh deploy.
- Missing generic base-image errors during a complete snapshot restore indicate
  outdated Terraform sources. Restore mode must skip that image lookup.
- DNS caches can retain the old load balancer address until TTL expiry. Check
  authoritative Cloudflare records as well as the local resolver.
- The restore health checks connect to the Terraform-managed load balancer IP
  with `--tls-server-name=api.DOMAIN`. This preserves certificate validation and
  avoids a workstation resolver's cached NXDOMAIN. The original kubeconfig is
  unchanged. For a temporary manual check while local DNS recovers:

  ```bash
  oc --server=https://LOAD_BALANCER_IP:6443 --tls-server-name=api.DOMAIN get nodes
  ```
- The load balancer can receive a new public address; original node IPs are
  retained. Cloudflare records managed by this repository are recreated.
- Manual changes outside Terraform are not automatically reproduced.
- Attached Hetzner volumes, private node networks and unmanaged/autoscaled nodes
  are outside this disk-restore path. External storage requires its own backup.
- Long shutdowns and expired certificates can need additional OKD recovery.
- Snapshot storage and retained IPv4 addresses remain billable. Restored cloud
  resources also accrue charges. `--no-autodestroy` leaves the cluster running.

## Execution record: 2026-10-18

- Domain: `okd4.myhelpdesk.gr` (legacy workspace).
- Snapshot set: `20261018T074537Z-28c39ba5`.
- Saved node: `master01.okd4.myhelpdesk.gr`, `cpx42`.
- Node image: `445011302`; retained node IPv4: `167.233.226.41`.
- Command: `./deploy-okd.sh --restore-snapshot 20261018T074537Z-28c39ba5 --no-autodestroy --yes`.
- Initial attempt: stopped before server creation because Terraform required a
  removed generic CoreOS image. Corrected the image-selection dependency and
  validated Terraform in the original toolbox container.
- Result: **restored successfully**, verified on 2026-10-18 at 08:07 UTC.
- Restored server: `171008163`, retained IPv4 `167.233.226.41`; node Ready.
- Recreated load balancer: `8070674`, IPv4 `167.235.235.132`.
- Load balancer ports `80`, `443`, `6443`, and `22623`: all healthy.
- API readiness endpoint: `ok`; cluster operators healthy: **34/34**.
- Cloudflare A records `api`, `api-int`, `apps`, and `*.apps` point to
  `167.235.235.132`; `etcd-0` points to `167.233.226.41`. All five verified
  through the Cloudflare API with proxying disabled.
- A workstation DNS resolver cached NXDOMAIN after teardown. Corrected restore
  health checks to use the new load balancer IP with original TLS hostname.
  The waiting health-check process was stopped and the exact restore retried;
  the retry preserved the already restored server and completed successfully.
- Temporary diagnostic SSH firewall was restricted to the operator workstation
  IPv4 `/32` and removed after diagnosis. No diagnostic access remains.
- Automatic teardown: **disabled**; the restored cluster remains running.
- Private transcript: `logs/restore-20261018T074537Z-28c39ba5.log`.
- Sanitized verification evidence:
  `logs/restore-verification-20261018T074537Z-28c39ba5.json`.
- Jira tracking: pending Atlassian connection and project selection.

### Primary IP missing during restore

A Hetzner HTTP 404 for a saved `primary_ips/ID` means that required resource is
not available to the configured project token. Local `ready` status records
successful snapshot creation; it does not prove that every cloud dependency
still exists. Check the original project and its retained Primary IPs. Both
original IPv4 and IPv6 must remain available with the saved addresses. The
existing restore flow cannot substitute new addresses merely by editing the
manifest. Preserve disk snapshots and artifacts for recovery investigation.
