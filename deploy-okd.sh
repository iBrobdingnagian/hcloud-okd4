#!/usr/bin/env bash
#
# deploy-okd.sh — interactive OKD-on-Hetzner deployment
# Automates the full procedure from DEPLOYMENT.md, including all the
# fixes discovered on 2026-06-09/10 (DNS cache, xz images, etcd firewall,
# container-only make targets, CSR rounds).
#
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
. "$REPO_ROOT/functions/context.sh"
cluster_dispatch deploy "$@"

# Every helper/function lives in functions/*.sh — keep this file as the
# orchestration flow only.
for f in "$REPO_ROOT"/functions/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done

usage() {
  cat <<'USAGE'
Usage: ./deploy-okd.sh [options]
  --cluster NAME    use clusters/NAME.yaml and isolated .work/NAME/ artifacts
  --plan            preview named-cluster configuration and live compute pricing
                    (combine only with --cluster; creates no cloud resources)
  --terraform-plan  show a Terraform resource diff using existing ignition/image
  --resume          resume interrupted installation, preserving ignition and state
  --region X        Hetzner location (e.g. nbg1, fsn1, hel1, ash, hil, sin)
  --profile N       deployment profile (skips the interactive menu):
                      1 = Production - Best Servers (3 masters / 3 workers,
                          dedicated CCX types)
                      2 = Production - Cost Optimized (3 masters / 3 workers,
                          cheapest qualifying types)
                      3 = Lab (pick --lab-topology and --lab-tier)
                      4 = Manual (interactive picker, default)
  --lab-topology T  profile 3 only: 1x0, 1x1, 1x2, 1x3 or 3x3 (masters x workers)
  --lab-tier T      profile 3 only: low, mid or high (cost/spec tier)
  --masters N       master count (1/3/5)
  --workers N       worker count
  --master-type T   server type for masters (e.g. cpx42)
  --worker-type T   server type for workers
  --duration D      lab duration: hours (8) or minutes (90m)
  --release R       OKD line (4.16) or full tag (4.16.0-okd-scos.1)
  --rebuild-image   build the CoreOS snapshot even if one exists for this release
  --no-admin        skip the htpasswd admin step
  --admin           create the htpasswd admin user on an already-running
                    cluster (interactive; the password is prompted)
  --monitoring      configure monitoring & alerting (user-workload monitoring,
                    Alertmanager, Grafana dashboards) — only available when
                    at least one schedulable node has more than 12 GB RAM;
                    works on a fresh deploy and on an already-running cluster
  --alert-webhook U send warning/critical alerts to webhook URL U
                    (Slack/Teams/generic; implies the Alertmanager config)
  --devops          install DevOps tooling on the running cluster (interactive
                    menu, or use --devops-components). Works on a fresh deploy
                    and on an already-running cluster.
  --devops-components LIST  comma list of: cert-manager,argocd,odf,jenkins,gitlab,
                    harbor,artifactory,awx,sonarqube,jaeger,opensearch,istio,kiali,
                    kafka,kafka-kraft,strimzi-kafka,appsim,loki,loki-operator,tempo,
                    tempo-operator,otel,otel-operator,observability,observability-operator,
                    appsim-gitops,appsim-boutique,appsim-events,appsim-awx,
                    appsim-cicd,appsim-mesh,appsim-bookinfo,appsim-emojivoto,appsim-all
                    (the *-operator variants use OLM + in-cluster MinIO for S3;
                    the bare names are lightweight Helm single-binary installs;
                    appsim-* are real-world application simulations across the stack;
                    appsim-cicd honours APPSIM_CICD_CI=jenkins|gitlab for the CI engine)
  --storage-backend B  storageclass backend for components needing PVCs:
                      local (node volumes, default) or smb (Hetzner Storage Box)
  --version-policy P  operator version policy: n-2 (default; install two
                      releases behind the channel head for stability) or
                      latest (track the channel head)
  --no-autodestroy  do not schedule the automatic teardown
  --autodestroy-at D schedule auto-destroy after D (hours or Nm minutes,
                    same syntax as --duration); defaults to --duration
  --scale           if an existing cluster is found, offer to add masters/
                    workers to it instead of refusing to proceed
  --rescale         change CPU/RAM of existing nodes in place WITHOUT destroying
                    the cluster (Hetzner change-type, disk kept). Rolling, one
                    node at a time (drain -> power off -> change type -> power on
                    -> uncordon); masters singly so etcd keeps quorum.
  --rescale-role R  which nodes: master | worker | all
  --rescale-type T  target Hetzner server type (e.g. cx43)
  --autoscale       run a load-driven worker autoscaler against the running
                    cluster (foreground watch loop; Ctrl-C to stop). Adds a
                    worker when pods are Pending for cpu/memory, removes one
                    when load fits on fewer workers. Workers only.
                    NOTE: native MachineSets/MachineAutoscaler can't run on
                    Hetzner (platform "none"); this drives the --scale path.
  --cluster-autoscaler  deploy the upstream Kubernetes Cluster Autoscaler with
                    the native Hetzner cloud provider (resident in-cluster pod +
                    a CSR auto-approver). Scales a node pool via the Hetzner API
                    on Pending-pod pressure. EXPERIMENTAL on platform "none".
  --ca-type T       autoscaled pool server type (default: the current worker
                    type, TF_VAR_server_type_worker)
  --ca-min N        pool minimum nodes (default 0)
  --ca-max N        pool maximum nodes (default 3)
  --ca-smoke-test   prove the autoscaler end-to-end: create a throwaway Pending
                    workload so a real Hetzner node is provisioned and joins,
                    then delete it (the node scales down after the cooldown)
  --autoscale-min N   floor for worker count (default: current)
  --autoscale-max N   ceiling for worker count (default: current + 2)
  --autoscale-interval S  poll interval in seconds (default 60, min 15)
  --yes             non-interactive: defaults for everything not given above
                    (profile 2: 3 masters, 3 workers, current region,
                    cheapest types, 8h)
  --help            this text
USAGE
}
FLAG_REGION="" FLAG_MASTERS="" FLAG_WORKERS="" FLAG_MASTER_TYPE="" FLAG_WORKER_TYPE=""
FLAG_DURATION="" FLAG_RELEASE="" REBUILD_IMAGE=0 NO_ADMIN=0 NO_AUTODESTROY=0 ASSUME_YES=0
FLAG_PROFILE="" FLAG_LAB_TOPOLOGY="" FLAG_LAB_TIER="" FLAG_AUTODESTROY_AT="" FLAG_SCALE=0
FLAG_MONITORING=0 ALERT_WEBHOOK="" FLAG_ADMIN=0
FLAG_AUTOSCALE=0 FLAG_AUTOSCALE_MIN="" FLAG_AUTOSCALE_MAX="" FLAG_AUTOSCALE_INTERVAL=""
FLAG_DEVOPS=0 FLAG_DEVOPS_COMPONENTS="" FLAG_STORAGE_BACKEND=""
FLAG_RESCALE=0 FLAG_RESCALE_ROLE="" FLAG_RESCALE_TYPE=""
FLAG_CA=0 FLAG_CA_TYPE="" FLAG_CA_MIN="" FLAG_CA_MAX="" FLAG_CA_SMOKE=0
FLAG_RESUME=0 FLAG_TERRAFORM_PLAN=0
VERSION_POLICY="${VERSION_POLICY:-n-2}"   # operator version policy: n-2 | latest
while [ $# -gt 0 ]; do
  case "$1" in
    --resume)         FLAG_RESUME=1; shift ;;
    --terraform-plan) FLAG_TERRAFORM_PLAN=1; shift ;;
    --plan)           err "--plan requires --cluster NAME" ;;
    --region)         FLAG_REGION=${2:?--region needs a value}; shift 2 ;;
    --profile)        FLAG_PROFILE=${2:?--profile needs a value}; shift 2 ;;
    --lab-topology)   FLAG_LAB_TOPOLOGY=${2:?--lab-topology needs a value}; shift 2 ;;
    --lab-tier)       FLAG_LAB_TIER=${2:?--lab-tier needs a value}; shift 2 ;;
    --masters)        FLAG_MASTERS=${2:?--masters needs a value}; shift 2 ;;
    --workers)        FLAG_WORKERS=${2:?--workers needs a value}; shift 2 ;;
    --master-type)    FLAG_MASTER_TYPE=${2:?--master-type needs a value}; shift 2 ;;
    --worker-type)    FLAG_WORKER_TYPE=${2:?--worker-type needs a value}; shift 2 ;;
    --duration)       FLAG_DURATION=${2:?--duration needs a value}; shift 2 ;;
    --autodestroy-at) FLAG_AUTODESTROY_AT=${2:?--autodestroy-at needs a value}; shift 2 ;;
    --release)        FLAG_RELEASE=${2:?--release needs a value}; shift 2 ;;
    --rebuild-image)  REBUILD_IMAGE=1; shift ;;
    --no-admin)       NO_ADMIN=1; shift ;;
    --admin)          FLAG_ADMIN=1; shift ;;
    --monitoring)     FLAG_MONITORING=1; shift ;;
    --alert-webhook)  ALERT_WEBHOOK=${2:?--alert-webhook needs a URL}; FLAG_MONITORING=1; shift 2 ;;
    --devops)             FLAG_DEVOPS=1; shift ;;
    --devops-components)  FLAG_DEVOPS_COMPONENTS=${2:?--devops-components needs a value}; FLAG_DEVOPS=1; shift 2 ;;
    --storage-backend)    FLAG_STORAGE_BACKEND=${2:?--storage-backend needs a value}; shift 2 ;;
    --version-policy)     VERSION_POLICY=${2:?--version-policy needs a value}; shift 2 ;;
    --no-autodestroy) NO_AUTODESTROY=1; shift ;;
    --scale)          FLAG_SCALE=1; shift ;;
    --rescale)            FLAG_RESCALE=1; shift ;;
    --rescale-role)       FLAG_RESCALE_ROLE=${2:?--rescale-role needs master|worker|all}; FLAG_RESCALE=1; shift 2 ;;
    --rescale-type)       FLAG_RESCALE_TYPE=${2:?--rescale-type needs a server type}; FLAG_RESCALE=1; shift 2 ;;
    --cluster-autoscaler) FLAG_CA=1; shift ;;
    --ca-type)            FLAG_CA_TYPE=${2:?--ca-type needs a server type}; FLAG_CA=1; shift 2 ;;
    --ca-min)             FLAG_CA_MIN=${2:?--ca-min needs a value}; FLAG_CA=1; shift 2 ;;
    --ca-max)             FLAG_CA_MAX=${2:?--ca-max needs a value}; FLAG_CA=1; shift 2 ;;
    --ca-smoke-test)      FLAG_CA_SMOKE=1; shift ;;
    --autoscale)          FLAG_AUTOSCALE=1; shift ;;
    --autoscale-min)      FLAG_AUTOSCALE_MIN=${2:?--autoscale-min needs a value}; shift 2 ;;
    --autoscale-max)      FLAG_AUTOSCALE_MAX=${2:?--autoscale-max needs a value}; shift 2 ;;
    --autoscale-interval) FLAG_AUTOSCALE_INTERVAL=${2:?--autoscale-interval needs a value}; shift 2 ;;
    --yes)            ASSUME_YES=1; NO_ADMIN=1; shift ;;  # passwords can't be prompted non-interactively
    --help)           usage; exit 0 ;;
    *)                usage; err "unknown option: $1" ;;
  esac
done

validate_deploy_flags
start_progress_server   # functions/progress.sh
load_env
DOMAIN=${TF_VAR_dns_domain:?TF_VAR_dns_domain is required}
export KUBECONFIG="$PWD/ignition/auth/kubeconfig"
if [ "$FLAG_TERRAFORM_PLAN" = 1 ]; then
  infrastructure_plan
  exit 0
fi
if [ "$FLAG_RESUME" = 1 ]; then
  [ "$FLAG_SCALE$FLAG_AUTOSCALE$FLAG_RESCALE$FLAG_ADMIN$FLAG_CA$FLAG_CA_SMOKE" = 000000 ] \
    || err "--resume cannot be combined with another lifecycle operation"
  [ -z "$FLAG_REGION$FLAG_RELEASE$FLAG_MASTERS$FLAG_WORKERS$FLAG_MASTER_TYPE$FLAG_WORKER_TYPE$FLAG_PROFILE" ] \
    || err "--resume uses the recorded configuration; do not pass topology/release overrides"
  phase_done configured || err "no deployment checkpoint; cannot resume safely"
fi

# ── pre-flight checks (functions/preflight.sh) ───────────────────────────
preflight_checks

# ── 0. adaptive scale-up: is there already a cluster for this domain? ────
if [ -n "$DOMAIN" ]; then
  EXISTING_SERVERS=$(cluster_servers | jq '.servers | length')
else
  EXISTING_SERVERS=0
fi

# ── 0. autoscaler mode: a foreground watch loop against a running cluster ─
if [ "$FLAG_AUTOSCALE" = 1 ]; then
  [ "${EXISTING_SERVERS:-0}" -gt 0 ] 2>/dev/null \
    || err "--autoscale needs a running cluster for $DOMAIN, found none — deploy one first"
  run_autoscale            # functions/autoscale.sh — loops until Ctrl-C
  exit 0
fi

# ── 0. existing cluster? offer scale / monitoring instead of a deploy ────
if [ "$FLAG_RESUME" = 0 ] && [ "${EXISTING_SERVERS:-0}" -gt 0 ] 2>/dev/null; then
  if phase_done configured && ! phase_done ready; then
    err "installation is incomplete; use --resume before day-2 operations"
  fi
  handle_existing_cluster   # functions/cluster-scale.sh — always exits
fi

if [ "$FLAG_RESUME" = 0 ]; then
  [ ! -d ignition ] && [ ! -d config ] \
    || err "installation artifacts already exist; use --resume or archive them explicitly after teardown"

# ── 0b. deployment profile (functions/profiles.sh) ────────────────────────
select_profile

# ── 1. region & live capacity/pricing (functions/region.sh) ──────────────
select_region

# ── 2. topology & instance types ─────────────────────────────────────────
# profiles 1-3 already set MASTERS/WORKERS; profile 4 (manual) prompts here
if [ "$PROFILE" = 4 ]; then
  if [ -n "$FLAG_MASTERS" ]; then MASTERS=$FLAG_MASTERS
  elif [ "$ASSUME_YES" = 1 ]; then MASTERS=3
  else printf '\nHow many MASTER nodes? [1]: '; read -r MASTERS; MASTERS=${MASTERS:-1}; fi
  if [ -n "$FLAG_WORKERS" ]; then WORKERS=$FLAG_WORKERS
  elif [ "$ASSUME_YES" = 1 ]; then WORKERS=3
  else printf 'How many WORKER nodes? [1]: '; read -r WORKERS; WORKERS=${WORKERS:-1}; fi
fi
case "$MASTERS$WORKERS" in *[!0-9]*) err "counts must be numbers";; esac
[ "$MASTERS" -ge 1 ] || err "at least 1 master required"

# etcd quorum: an even member count tolerates no more failures than the
# next-lower odd one, and 2 masters tolerate NONE (worse than 1)
if [ $((MASTERS % 2)) -eq 0 ]; then
  cat <<'QUORUM'

  WARNING: even master counts are an etcd anti-pattern. etcd needs a strict
  majority (quorum) for every write: with 2 masters, quorum is 2, so losing
  EITHER node freezes the whole control plane — more cost than 1 master,
  less reliability. 4 tolerates no more failures than 3. Use 1, 3 or 5.
QUORUM
  [ "$ASSUME_YES" = 1 ] && err "even master count ($MASTERS) rejected in --yes mode — use 1, 3 or 5"
  printf 'Continue anyway? [y/N]: '
  read -r QOK
  [ "$QOK" = "y" ] || [ "$QOK" = "Y" ] || { echo "Aborted."; exit 0; }
fi

pick_type "master" "$MIN_C_MASTER" "$MIN_R_MASTER" "$FLAG_MASTER_TYPE" "$TYPE_PREFIX" "$TYPE_STRATEGY"
MASTER_TYPE=$PICKED_TYPE MASTER_PRICE=$PICKED_PRICE
if [ "$WORKERS" -gt 0 ]; then
  pick_type "worker" "$MIN_C_WORKER" "$MIN_R_WORKER" "$FLAG_WORKER_TYPE" "$TYPE_PREFIX" "$TYPE_STRATEGY"
  WORKER_TYPE=$PICKED_TYPE WORKER_PRICE=$PICKED_PRICE
else
  # single-node topology (0 workers): the master is schedulable (compute
  # replicas stay 0), so the cluster needs no worker VMs. Terraform still
  # needs a valid worker type for the zero-replica pool — reuse the master
  # type and charge nothing. Add workers later with: ./deploy-okd.sh --scale
  WORKER_TYPE=$MASTER_TYPE WORKER_PRICE=0
  echo "    worker nodes: 0 (single-node — master is schedulable; scale up later with --scale)"
fi

# bootstrap mirrors the master choice (temporary, deleted after bootstrap);
# ignition gets the cheapest available type (it only serves one file)
BOOTSTRAP_TYPE=$MASTER_TYPE BOOTSTRAP_PRICE=$MASTER_PRICE
IGNITION_TYPE=$(echo "$CANDIDATES" | head -1 | cut -f1)
IGNITION_PRICE=$(echo "$CANDIDATES" | head -1 | cut -f5)
if [ -n "${CLUSTER_ID:-}" ]; then
  IGNITION_TYPE=$TF_VAR_server_type_ignition
  IGNITION_PRICE=$(echo "$CANDIDATES" | awk -F'\t' -v t="$IGNITION_TYPE" '$1 == t {print $5}')
  [ -n "$IGNITION_PRICE" ] || err "configured ignition type $IGNITION_TYPE is unavailable in $LOC"
fi

# packer build server (temporary, only writes the CoreOS image in rescue
# mode): keep cx33 if this region has it, else cheapest with >=4 GB RAM
if echo "$CANDIDATES" | cut -f1 | grep -qx "cx33"; then
  PACKER_TYPE=cx33
else
  PACKER_TYPE=$(echo "$CANDIDATES" | awk -F'\t' '$3>=4' | head -1 | cut -f1)
fi
[ -n "$PACKER_TYPE" ] || err "no packer-capable type (>=4 GB RAM) available in $LOC"
echo
echo "  bootstrap : $BOOTSTRAP_TYPE (same as master, temporary)"
echo "  ignition  : $IGNITION_TYPE (cheapest available, temporary)"
echo "  packer    : $PACKER_TYPE (image build, temporary)"

# ── 3. cost estimate ─────────────────────────────────────────────────────
if [ -n "$FLAG_DURATION" ]; then DUR=$FLAG_DURATION
elif [ "$ASSUME_YES" = 1 ]; then DUR=8
else
  printf '\nHow long will the lab run? Hours (e.g. 8) or minutes with m suffix (e.g. 90m) [8]: '
  read -r DUR; DUR=${DUR:-8}
fi
case "$DUR" in
  *m) HOURS=$(awk -v m="${DUR%m}" 'BEGIN{printf "%.2f", m/60}') ;;
  *)  HOURS=$DUR ;;
esac
awk -v h="$HOURS" 'BEGIN{exit !(h+0>0)}' || err "invalid duration: $DUR"

awk -v m="$MASTERS" -v w="$WORKERS" -v pm="$MASTER_PRICE" -v pw="$WORKER_PRICE" \
    -v pb="$BOOTSTRAP_PRICE" -v pi="$IGNITION_PRICE" -v h="$HOURS" \
    -v mt="$MASTER_TYPE" -v wt="$WORKER_TYPE" 'BEGIN{
  cluster = m*pm + w*pw
  temp    = pb + pi
  printf "\n  Cost estimate (gross prices, Hetzner bills per started hour):\n"
  printf "    %d x master %-7s : %.4f EUR/h\n", m, mt, m*pm
  printf "    %d x worker %-7s : %.4f EUR/h\n", w, wt, w*pw
  printf "    cluster hourly rate  : %.4f EUR/h\n", cluster
  printf "    bootstrap + ignition : %.4f EUR one-off (live ~1h during install)\n", temp
  printf "    ───────────────────────────────────────\n"
  printf "    estimated for %.2f h : %.2f EUR\n", h, cluster*h + temp
  printf "    (excludes load balancer, primary IPs, snapshot storage and traffic)\n"
}'
if [ "$ASSUME_YES" = 1 ]; then
  echo; echo "Proceeding (--yes)."
else
  printf '\nProceed with the deployment? [y/N]: '
  read -r GO
  [ "$GO" = "y" ] || [ "$GO" = "Y" ] || { echo "Aborted."; exit 0; }
fi

# ── 4. version (functions/release.sh) ─────────────────────────────────────
select_release

# ── 5. write the choices into .env / install-config.yaml ────────────────
step "Updating .env and install-config.yaml" "instant"
sedi -E \
  -e "s|^OPENSHIFT_RELEASE=.*|OPENSHIFT_RELEASE=$OPENSHIFT_RELEASE|" \
  -e "s|^TF_VAR_replicas_master=.*|TF_VAR_replicas_master=$MASTERS|" \
  -e "s|^TF_VAR_replicas_worker=.*|TF_VAR_replicas_worker=$WORKERS|" \
  -e "s|^TF_VAR_server_type_master=.*|TF_VAR_server_type_master=$MASTER_TYPE|" \
  -e "s|^TF_VAR_server_type_worker=.*|TF_VAR_server_type_worker=$WORKER_TYPE|" \
  -e "s|^TF_VAR_server_type_bootstrap=.*|TF_VAR_server_type_bootstrap=$BOOTSTRAP_TYPE|" \
  -e "s|^TF_VAR_server_type_ignition=.*|TF_VAR_server_type_ignition=$IGNITION_TYPE|" \
  -e "s|^TF_VAR_location=.*|TF_VAR_location=$LOC|" \
  -e "s|^TF_VAR_network_zone=.*|TF_VAR_network_zone=$NETWORK_ZONE|" \
  -e "s|^PACKER_LOCATION=.*|PACKER_LOCATION=$LOC|" \
  -e "s|^PACKER_SERVER_TYPE=.*|PACKER_SERVER_TYPE=$PACKER_TYPE|" .env
# older .env files predate this line; sed substitution is a no-op then
grep -q '^TF_VAR_network_zone=' .env \
  || echo "TF_VAR_network_zone=$NETWORK_ZONE" >> .env

# controlPlane.replicas = masters; compute.replicas stays 0 (terraform
# creates the worker VMs; they join via CSR approval)
python3 - "$MASTERS" <<'EOF'
import sys, yaml
m = int(sys.argv[1])
d = yaml.safe_load(open('install-config.yaml'))
d['controlPlane']['replicas'] = m
d['compute'][0]['replicas'] = 0
yaml.safe_dump(d, open('install-config.yaml', 'w'), default_flow_style=False)
EOF

load_env
python3 "$REPO_ROOT/scripts/cluster_context.py" set-env .env LAB_DURATION "$DUR"
phase_mark configured
else
  MASTERS=$TF_VAR_replicas_master WORKERS=$TF_VAR_replicas_worker
  OPENSHIFT_RELEASE=${OPENSHIFT_RELEASE:?recorded release is missing}
  DUR=${FLAG_DURATION:-${LAB_DURATION:-8}}
  log "Resuming $DOMAIN with the recorded release and topology"
fi
TOOLBOX=quay.io/slauger/hcloud-okd4:$OPENSHIFT_RELEASE
DOMAIN=$TF_VAR_dns_domain

# (existing-cluster / scale-up check already happened in step 0, above)

# ── 6. toolbox image (fetch/build are the ONLY host-side make targets) ──
step "Toolbox image" "skipped if cached, else 5-10 min download+build"
if docker image inspect "$TOOLBOX" >/dev/null 2>&1; then
  echo "    $TOOLBOX already present — skipping fetch/build"
else
  log "Fetching installer tarballs (~700 MB) and building toolbox image"
  make fetch
  make build
fi

# ── 7. generate once; retain installer identity when resuming ──────────
if ! phase_done ignition; then
  step "Generating manifests and ignition configs" "~1 min"
  if [ ! -f ignition/auth/kubeconfig ]; then
    [ ! -d config ] || [ -f config/.openshift_install_state.json ] \
      || err "partial config directory requires inspection; refusing to regenerate identity"
    [ -d config ] || tb "make generate_manifests"
    tb "make generate_ignition"
  fi
  validate_ignition
  phase_mark ignition
else
  validate_ignition
  log "Reusing existing ignition and cluster credentials"
fi

# ── 8. CoreOS snapshot (reused when one exists for this release) ─────────
step "CoreOS image" "skipped if a snapshot for this release exists, else 2-5 min"
FCOS_RELEASE=$(tb "openshift-install coreos print-stream-json \
  | jq -r '.architectures.x86_64.artifacts.qemu.release'" | tr -d '[:space:]')
[ -n "$FCOS_RELEASE" ] || err "could not determine the CoreOS release from the toolbox"
sedi -E -e "s|^TF_VAR_fcos_release=.*|TF_VAR_fcos_release=$FCOS_RELEASE|" .env
grep -q '^TF_VAR_fcos_release=' .env \
  || echo "TF_VAR_fcos_release=$FCOS_RELEASE" >> .env
# A failed discovery must not trigger a new billable image build.
SNAP_COUNT=$(curl -fsS --connect-timeout 10 --max-time 60 -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/images?type=snapshot&status=available&label_selector=os=fcos,fcos_release=$FCOS_RELEASE" \
  | jq -er '.images | if type == "array" then length else error("invalid image response") end') \
  || err "could not discover CoreOS snapshots; retry with --resume when the API is available"
if [ "${SNAP_COUNT:-0}" -gt 0 ] 2>/dev/null && [ "$REBUILD_IMAGE" = 0 ]; then
  echo "    snapshot for CoreOS $FCOS_RELEASE already exists — skipping build (--rebuild-image to force)"
else
  [ "$SSH22_BLOCKED" = 0 ] \
    || err "a CoreOS image build is needed (no snapshot for $FCOS_RELEASE) but outbound tcp/22 is blocked here — build once from a network that allows SSH, or pick a release whose snapshot exists"
  tb "make hcloud_image"
fi
phase_mark image

# ── 9. infrastructure + bootstrap ────────────────────────────────────────
if ! phase_done bootstrap-complete; then
step "Deploying infrastructure (terraform + ansible, BOOTSTRAP=true)" "3-5 min"
tb "make infrastructure BOOTSTRAP=true"
flush_dns   # records were just (re)created — drop any negative cache

# A closed MCS port is normal while the OS image and bootstrap containers
# are being pulled/rendered. Never reset a node based on elapsed time alone:
# a reset can interrupt that work and leave bootstrap unable to restart.
# If the installer times out, inspect its console/journal before recovery.

step "Waiting for bootstrap to complete" "15-40 min (longest phase)"
echo "    Watcher is read-only; if it times out the install continues — retried once."
tb "make wait_bootstrap" || { log "Watcher timed out — retrying once"; tb "make wait_bootstrap"; }
phase_mark bootstrap-complete
fi

# ── 10. remove bootstrap, wait for completion ─────────────────────────────
if ! phase_done bootstrap-removed; then
step "Removing bootstrap + ignition nodes" "1-2 min"
tb "make infrastructure"
phase_mark bootstrap-removed
fi

# ── install watchdog (functions/watchdog.sh) runs during the wait ────────
export KUBECONFIG=$PWD/ignition/auth/kubeconfig
install_watchdog &
WATCHDOG=$!
trap 'deployment_status=$?; trap - EXIT; if [ -n "${WATCHDOG:-}" ]; then kill "$WATCHDOG" 2>/dev/null || true; fi; if [ -n "${RELDIR:-}" ]; then rm -rf "$RELDIR" || true; fi; exit "$deployment_status"' EXIT

step "Waiting for install completion" "5-25 min"
tb "make wait_completion" || { log "Watcher timed out — retrying once"; tb "make wait_completion"; }
phase_mark installed
kill "$WATCHDOG" 2>/dev/null || true

# ── 11. join the workers (CSR rounds until everyone is Ready) ─────────────
export KUBECONFIG=$PWD/ignition/auth/kubeconfig
EXPECTED=$((MASTERS + WORKERS))
step "Approving CSRs until all $EXPECTED nodes are Ready" "2-10 min"
tries=0
while [ $tries -lt 60 ]; do
  oc get csr -o name 2>/dev/null | xargs -r oc adm certificate approve 2>/dev/null || true
  READY=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  [ "$READY" -ge "$EXPECTED" ] && break
  tries=$((tries+1)); sleep 20
done
oc get nodes
[ "${READY:-0}" -ge "$EXPECTED" ] || err "not all nodes became Ready — approve remaining CSRs manually: oc get csr"
verify_cluster_health
phase_mark ready
progress_step deploy "Post-install (admin user, monitoring, DevOps add-ons)" "waits for your answers"

# ── 11b. schedule the teardown (functions/autodestroy.sh) ─────────────────
schedule_autodestroy

# ── 11c. htpasswd admin user (functions/admin.sh) ─────────────────────────
if [ "$NO_ADMIN" = 0 ]; then
  printf '\nCreate htpasswd admin user (replaces kubeadmin)? [Y/n]: '
  read -r MKADMIN; MKADMIN=${MKADMIN:-y}
  if [ "$MKADMIN" = "y" ] || [ "$MKADMIN" = "Y" ]; then
    create_admin || true
  fi
fi

# ── 11d. monitoring & alerting (optional, gated on >12 GB RAM nodes) ─────
if [ "$FLAG_MONITORING" = 1 ]; then
  install_monitoring || err "requested monitoring installation failed; rerun with --monitoring"
elif [ "$ASSUME_YES" = 0 ]; then
  MON_MAX_GB=$(max_node_ram_gb)
  if awk -v g="${MON_MAX_GB:-0}" 'BEGIN{exit !(g+0>12)}'; then
    printf '\nConfigure monitoring & alerting (user-workload monitoring; largest node %s GB RAM)? [y/N]: ' "$MON_MAX_GB"
    read -r MKMON
    if [ "$MKMON" = "y" ] || [ "$MKMON" = "Y" ]; then
      install_monitoring || true
    fi
  else
    echo
    echo "    (monitoring & alerting not offered: needs a node with >12 GB RAM, largest is ${MON_MAX_GB:-0} GB —"
    echo "     it can be added later with ./deploy-okd.sh --monitoring after scaling to bigger nodes)"
  fi
fi

# ── 11e. DevOps tooling (optional: ArgoCD / Jenkins / GitLab) ────────────
if [ "$FLAG_DEVOPS" = 1 ]; then
  install_devops || err "one or more requested addons failed; rerun with --devops-components"
elif [ "$ASSUME_YES" = 0 ]; then
  printf '\nInstall DevOps tooling (ArgoCD / Jenkins / GitLab)? [y/N]: '
  read -r MKDEV
  if [ "$MKDEV" = "y" ] || [ "$MKDEV" = "Y" ]; then
    install_devops || true
  fi
fi

# ── 12. summary ──────────────────────────────────────────────────────────
if [ -n "$ADMIN_CREATED" ]; then
  CRED_USER=$ADMIN_CREATED
  CRED_PASS="(the password you typed)"
else
  CRED_USER=kubeadmin
  CRED_PASS="read $PWD/ignition/auth/kubeadmin-password (if kubeadmin is still enabled)"
fi
cat <<SUMMARY

═══════════════════════════════════════════════════════════════════
  OKD $OPENSHIFT_RELEASE deployed: $MASTERS master(s), $WORKERS worker(s)
  Total time: $(elapsed)
═══════════════════════════════════════════════════════════════════

  Web console : https://console-openshift-console.apps.$DOMAIN
  Username    : $CRED_USER
  Password    : $CRED_PASS

  CLI         : export KUBECONFIG="$PWD/ignition/auth/kubeconfig"
  SSH         : ssh -i "$PWD/okd4_new_id_rsa" core@<node-ip>

  $AUTODESTROY_NOTE
  $MONITORING_NOTE${DEVOPS_NOTE:+
  $DEVOPS_NOTE}
SUMMARY
if [ -z "$ADMIN_CREATED" ]; then
cat <<'HOWTO'
───────────────────────────────────────────────────────────────────
  "You are logged in as a temporary administrative user."
  To replace kubeadmin with a real htpasswd user:

    htpasswd -c -B -b users.htpasswd admin 'YOUR_PASSWORD'
    oc create secret generic htpass-secret \
       --from-file=htpasswd=users.htpasswd -n openshift-config
    oc apply -f - <<'EOF'
    apiVersion: config.openshift.io/v1
    kind: OAuth
    metadata:
      name: cluster
    spec:
      identityProviders:
      - name: htpasswd_provider
        mappingMethod: claim
        type: HTPasswd
        htpasswd:
          fileData:
            name: htpass-secret
    EOF
    oc adm policy add-cluster-role-to-user cluster-admin admin

  After verifying the new admin works, remove kubeadmin:
    oc delete secret kubeadmin -n kube-system
───────────────────────────────────────────────────────────────────
HOWTO
fi
