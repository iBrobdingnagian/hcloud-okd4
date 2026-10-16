# Independent clusters from one checkout

Named clusters reuse the Terraform/Packer/Ansible source but have separate local
state, installer identity, kubeconfig, inventory, credentials, and timers. These
commands provision independent clusters; they do not configure cross-cluster
routing or a shared management plane.

## Configure a cluster

The host needs Python 3 with PyYAML, Bash, jq, curl, Docker, make, and the OpenShift
CLI. Install the Python dependency with your normal environment manager, or use
`python3 -m pip install -r requirements-dev.txt` in a virtual environment.

```bash
mkdir -p .secrets
chmod 700 .secrets
cp clusters/dev.yaml.example clusters/dev.yaml
cp clusters/credentials.env.example .secrets/dev.env
chmod 600 .secrets/dev.env
```

Edit `clusters/dev.yaml` with your domain, Cloudflare zone ID, full OKD release
tag, location, server types, and networks. The release and server types in the
example are illustrative, not a compatibility recommendation. Put the cloud
tokens in `.secrets/dev.env`. Put an SSH private key at the configured
`ssh_private_key` path and its public key at the same path plus `.pub`.
Register that public key in the selected Hetzner project so Ansible can reach
the ignition host. Credential files accept literal `KEY=value` entries, including
quoted values; shell commands and variable substitutions are never evaluated.

For staging, copy the example to `clusters/staging.yaml`, change `name` to
`staging`, and use a different domain. Allocate different machine, pod, and
service ranges if you expect to connect the clusters later. The validator checks
CIDR containment and overlaps within each cluster. Independent isolated clusters
may reuse address ranges. Each configuration can reference a different Hetzner
project's credentials.

```bash
./deploy-okd.sh --cluster dev --plan
./deploy-okd.sh --cluster dev --yes
./deploy-okd.sh --cluster staging --yes
./power-okd.sh status --cluster dev
./deploy-okd.sh --cluster dev --scale --workers 4 --yes
./destroy-okd.sh --cluster dev --yes
```

`--plan` validates the YAML and displays desired topology, recorded local counts,
network settings, and live compute pricing when credentials are available. It
does not create cloud resources, start Docker, generate ignition, or render a
cluster working directory. It is a configuration preview, not a Terraform plan.
It only accepts `--cluster`; edit the YAML to preview different settings.

After ignition and the CoreOS snapshot have been prepared, a provider resource
diff is available with `--terraform-plan`. This uses the existing toolbox image
and does not start Docker or apply changes:

```bash
./deploy-okd.sh --cluster dev --terraform-plan --workers 4
```

Review the diff before changing existing infrastructure. Correcting the old
hardcoded load-balancer address can update its private network attachment.

## State, locking, and recovery

Generated files live under `.work/<name>/`, which is gitignored and private to
the current user. Source configuration remains under `clusters/`. Operational
choices, including scaling overrides and the resolved CoreOS release, are kept
in the generated `.env`. CLI overrides do not rewrite your committed YAML; update
the YAML to reflect a permanent change. `--scale` with no replica flags uses the
YAML counts. `--scale --workers 4` preserves the current master count, and
`--scale --masters 3` preserves the current worker count.

Each entry point holds a per-cluster OS lock for its entire run, including
preparation and child processes. A competing operation on the same cluster fails
immediately. Other clusters can run concurrently. The foreground autoscaler
holds its cluster's lock until stopped. Locks are released automatically on
normal exit or process termination; do not delete lock files to bypass them.
This is local coordination: do not operate the same cluster from multiple
machines/checkouts with separate state. Remote state and distributed operation
locking are not configured by this change.

Installation records completed phases in `.phases/`.
`logs/last-operation.json` records its exit code and completed phases without
copying credentials into a transcript. If a run fails:

```bash
./deploy-okd.sh --cluster dev --resume --yes
```

Resume uses the recorded release/topology and existing ignition, certificates,
and kubeconfig. It does not regenerate cluster identity. It reconciles unfinished
bootstrap infrastructure, removes bootstrap only after bootstrap completion, and
rechecks installation, node readiness, and cluster operators. Changed identity,
region, release, or networks are rejected for an existing named cluster. Partial
or expired installer assets may require manual recovery; resume does not renew
bootstrap certificates or repair a lost Terraform state.

Destroy keeps local state/credentials and shared CoreOS snapshots by default.
After confirmed teardown, archive the cluster directory before reusing its name
for a fresh installation. Never archive/delete its state while resources remain.
Teardown verifies local state ownership and stops rather than deleting unrelated
resources. Legacy autoscaler nodes can be identified only while their cluster
network still exists; a missing network requires manual ownership verification.

`autodestroy: false` is the named-cluster default. Set it to `true` to opt in;
`--no-autodestroy` overrides it. Scheduled commands retain the explicit cluster
name and use a cluster/checkout-specific timer name. Ensure the credentials and
configuration files remain available until the scheduled job runs.

## Existing single-cluster installations

Commands without `--cluster` continue using the repository's original `.env`,
`terraform/terraform.tfstate`, and `ignition/` directories. Existing state is not
automatically moved. A named configuration cannot reuse the legacy domain.
Keep using the original commands for that deployment and use names for new
clusters. Old installations without phase checkpoints cannot use `--resume`;
their existing day-2 commands remain available.

Existing unqualified auto-destroy timers created before this change are not
automatically cancelled by the new namespaced timer logic. Inspect/cancel those
old jobs before scheduling a replacement.

## Validation

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 tests/check_terraform_templates.py
terraform fmt -check -recursive terraform
terraform -chdir=terraform init -backend=false -input=false -lockfile=readonly
terraform -chdir=terraform validate
```

Tests use temporary directories and mocked cloud/cluster commands. They cover
isolation, lock contention, ownership, API errors, failed drains, configuration
validation, and rendered Ignition. They do not create cloud resources. Container
build tests remain separate. The repository's lab/test suitability still applies.
