#!/usr/bin/env bash
#
# destroy-okd.sh — tear down the OKD cluster on Hetzner
# Destroys all terraform-managed resources (servers, LB, network,
# firewalls, DNS records). Retains shared CoreOS snapshots and optionally
# removes the local install artifacts after backing up credentials.
#
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
. "$REPO_ROOT/functions/context.sh"
cluster_dispatch destroy "$@"
. "$REPO_ROOT/functions/lifecycle.sh"
. "$REPO_ROOT/functions/progress.sh"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
err() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) echo 'Usage: ./destroy-okd.sh [--cluster NAME] [--yes]'; exit 0 ;;
    *) err "unknown option: $1" ;;
  esac
done
start_progress_server
progress_step destroy "Verifying cluster ownership" "<1 min"
load_env
DOMAIN=${TF_VAR_dns_domain:?TF_VAR_dns_domain is required}
export KUBECONFIG="$PWD/ignition/auth/kubeconfig"
[ -s terraform/terraform.tfstate ] || err "local Terraform state is missing; refusing teardown"
python3 "$REPO_ROOT/scripts/check_state.py" terraform/terraform.tfstate "$DOMAIN" "${CLUSTER_ID:-}"
cluster_servers >/dev/null || err "could not verify live cluster ownership"

# A manual run cancels a pending auto-destroy job. The scheduled run itself
# (HCLOUD_OKD4_SCHEDULED=1, set in the launchd plist) must NOT do this —
# bootout would SIGTERM the job's own process tree mid-destroy.
LABEL=com.hcloud-okd4.autodestroy.${AUTODESTROY_ID}
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [ "$(uname)" = "Darwin" ] && [ -z "${HCLOUD_OKD4_SCHEDULED:-}" ]; then
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    log "Cancelling pending auto-destroy job"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  fi
  rm -f "$PLIST"
fi

UNIT=hcloud-okd4-autodestroy-${AUTODESTROY_ID}
if [ "$(uname)" = "Linux" ] && [ -z "${HCLOUD_OKD4_SCHEDULED:-}" ]; then
  if systemctl --user list-units --all "$UNIT.*" 2>/dev/null | grep -q "$UNIT"; then
    log "Cancelling pending auto-destroy timer"
    systemctl --user stop "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1 || true
  fi
  if [ -f .autodestroy-atjob ] && command -v atrm >/dev/null 2>&1; then
    log "Cancelling pending auto-destroy 'at' job"
    atrm "$(cat .autodestroy-atjob)" 2>/dev/null || true
    rm -f .autodestroy-atjob
  fi
fi

[ -f .env ] || err ".env not found"
load_env
TOOLBOX=quay.io/slauger/hcloud-okd4:${OPENSHIFT_RELEASE:?OPENSHIFT_RELEASE missing from .env}

# a scheduled run cannot assume Docker Desktop is up
command -v docker >/dev/null || err "docker is required"
if ! docker info >/dev/null 2>&1; then
  log "Docker daemon is not running — starting it"
  if [ "$(uname)" = "Darwin" ]; then
    open -a Docker || err "could not launch Docker Desktop"
  else
    sudo systemctl start docker || err "could not start docker via systemctl"
  fi
  printf '    waiting for the daemon'
  tries=0
  until docker info >/dev/null 2>&1; do
    tries=$((tries+1))
    [ $tries -le 60 ] || { echo; err "docker daemon did not come up within 2 minutes"; }
    printf '.'; sleep 2
  done
  echo " up"
fi
docker image inspect "$TOOLBOX" >/dev/null 2>&1 || err "toolbox image $TOOLBOX not found"

progress_step destroy "Confirming teardown" "waits for 'yes' (skipped with --yes)"
if [ "$ASSUME_YES" = 1 ]; then
  log "Non-interactive destroy (--yes): destroying infrastructure, keeping snapshots and local state"
else
  echo
  echo "This will PERMANENTLY DESTROY the cluster at $TF_VAR_dns_domain:"
  echo "  - all servers, the load balancer, network and firewalls"
  echo "  - all Cloudflare DNS records of the cluster"
  printf '\nType "yes" to continue: '
  read -r CONFIRM
  [ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }
fi

# ── cluster-autoscaler nodes (created via the Hetzner API, NOT terraform) ──
# The upstream cluster-autoscaler provisions servers directly through the
# Hetzner API, so `terraform destroy` neither knows nor removes them — and
# while they stay attached to the cluster network/firewall they BLOCK terraform
# from deleting those. Remove them first, scoped to this cluster: servers
# carrying this cluster's unique node-pool label, or (legacy only) attached
# to its verified network. A missing network never broadens the selection.
log "Removing cluster-autoscaler nodes (not managed by terraform)"
progress_step destroy "Removing cluster-autoscaler nodes" "<1 min"
CA_NETID=$(hcloud_list networks | jq -r --arg d "$DOMAIN" '.networks[] | select(.name == $d) | .id')
CA_NODES=$(ca_node_ids)
if [ -n "$CA_NODES" ]; then
  assert_cluster_context || err "cannot verify autoscaler cluster context"
  stop_cluster_autoscaler_before_destroy \
    || err "could not stop or inspect the autoscaler before teardown"
fi
if [ -n "$CA_NODES" ]; then
  echo "$CA_NODES" | while read -r id name; do
    [ -n "$id" ] || continue
    curl -fsS --max-time 60 -X DELETE -H "Authorization: Bearer $HCLOUD_TOKEN" \
      "https://api.hetzner.cloud/v1/servers/$id" >/dev/null || exit 1
    echo "  deleted autoscaled node ${name:-$id}"
  done
  printf '    waiting for them to be removed'
  for _ in $(seq 1 30); do CA_NODES=$(ca_node_ids); [ -z "$CA_NODES" ] && break; printf '.'; sleep 2; done
  [ -z "$CA_NODES" ] || err "autoscaled servers still exist; teardown stopped"
  echo " done"
else
  echo "  none found"
fi

log "Destroying infrastructure with terraform"
progress_step destroy "Destroying infrastructure with terraform" "2-5 min"
# chown the workspace back to the host user afterwards (the toolbox runs as
# root and would otherwise leave terraform state etc. root-owned)
docker run --rm --dns 1.1.1.1 --env-file .env \
  -e TF_CLI_ARGS_destroy=-auto-approve \
  -v "$PWD":/workspace -w /workspace "$TOOLBOX" \
  bash -c "make destroy; rc=\$?; chown -R $(id -u):$(id -g) /workspace; exit \$rc"

# The infrastructure is gone, so the deploy checkpoints no longer describe
# anything real. Left in place, the next deploy skips ignition generation and
# fails on the missing ignition/auth/kubeconfig.
rm -rf .phases
echo "  cleared deploy checkpoints (.phases/)"

# CoreOS images may be shared by multiple clusters. Retain them on teardown.
log "Keeping shared CoreOS snapshots (manage them separately in Hetzner)"

# ── local install state ──────────────────────────────────────────────────
progress_step destroy "Cleaning up local state" "instant"
if [ "$ASSUME_YES" = 0 ] && { [ -d ignition ] || [ -d config ]; }; then
  printf '\nRemove local config/ and ignition/ dirs (required before a reinstall)?\nCredentials will be backed up first. [y/N]: '
  read -r DELLOCAL
  if [ "$DELLOCAL" = "y" ] || [ "$DELLOCAL" = "Y" ]; then
    if [ -d ignition/auth ] && [ -n "$(ls -A ignition/auth 2>/dev/null)" ]; then
      BAK="ignition-auth-backup-$(date +%Y%m%d-%H%M%S)"
      cp -r ignition/auth "$BAK"
      echo "  credentials backed up to $BAK/"
    fi
    rm -rf config ignition
    echo "  removed config/ ignition/"
  fi
fi

echo
echo "Done. Notes:"
echo " - The Hetzner SSH key 'okd4-new-key' is kept (the next deploy needs it)."
echo " - DNS caches (macOS/Linux and Docker Desktop) may remember these records;"
echo "   the deploy script flushes/bypasses them automatically."
