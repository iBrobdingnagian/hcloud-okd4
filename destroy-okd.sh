#!/usr/bin/env bash
#
# destroy-okd.sh — tear down the OKD cluster on Hetzner
# Destroys all terraform-managed resources (servers, LB, network,
# firewalls, DNS records). Optionally deletes the CoreOS snapshot and
# the local install state.
#
set -euo pipefail
cd "$(dirname "$0")"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
err() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "") ;;
  *) err "unknown option: $1 (only --yes is supported)" ;;
esac

# A manual run cancels a pending auto-destroy job. The scheduled run itself
# (HCLOUD_OKD4_SCHEDULED=1, set in the launchd plist) must NOT do this —
# bootout would SIGTERM the job's own process tree mid-destroy.
LABEL=com.hcloud-okd4.autodestroy
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [ "$(uname)" = "Darwin" ] && [ -z "${HCLOUD_OKD4_SCHEDULED:-}" ]; then
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    log "Cancelling pending auto-destroy job"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  fi
  rm -f "$PLIST"
fi

[ -f .env ] || err ".env not found"
export $(grep -v '^#' .env | xargs)
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

log "Destroying infrastructure with terraform"
# chown the workspace back to the host user afterwards (the toolbox runs as
# root and would otherwise leave terraform state etc. root-owned)
docker run --rm --dns 1.1.1.1 --env-file .env \
  -e TF_CLI_ARGS_destroy=-auto-approve \
  -v "$PWD":/workspace -w /workspace "$TOOLBOX" \
  bash -c "make destroy; rc=\$?; chown -R $(id -u):$(id -g) /workspace; exit \$rc"

# ── CoreOS snapshot (terraform does not manage it) ───────────────────────
if [ "$ASSUME_YES" = 0 ]; then
SNAPSHOTS=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/images?type=snapshot" \
  | jq -r '.images[] | select(.description|startswith("fcos")) | "\(.id) \(.description)"')
if [ -n "$SNAPSHOTS" ]; then
  echo
  echo "CoreOS snapshots in the Hetzner project (small storage fee):"
  echo "$SNAPSHOTS" | sed 's/^/  /'
  printf 'Delete them? [y/N]: '
  read -r DELSNAP
  if [ "$DELSNAP" = "y" ] || [ "$DELSNAP" = "Y" ]; then
    echo "$SNAPSHOTS" | while read -r id _; do
      curl -s -X DELETE -H "Authorization: Bearer $HCLOUD_TOKEN" \
        "https://api.hetzner.cloud/v1/images/$id" >/dev/null && echo "  deleted $id"
    done
  fi
fi
fi

# ── local install state ──────────────────────────────────────────────────
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
