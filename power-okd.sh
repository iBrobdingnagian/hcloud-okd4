#!/usr/bin/env bash
#
# power-okd.sh — power control for the OKD cluster VMs on Hetzner
# Reboots, shuts down or powers on the cluster servers via the Hetzner
# API (no terraform, no cluster state touched — the disks are kept).
#
# Called directly, or through the reboot-okd.sh / shutdown-okd.sh wrappers.
#
set -euo pipefail
cd "$(dirname "$0")"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
err() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: ./power-okd.sh <action> [options] [server-name ...]

Actions:
  reboot      ACPI reboot (graceful; --hard = power cycle)
  shutdown    ACPI shutdown (graceful; --hard = pull the plug)
  poweron     power the servers back on
  status      list the cluster servers and their power state

Options:
  --role R    only servers of role R: master, worker, bootstrap,
              ignition, or all (default: all)
  --hard      skip the ACPI request; reset/poweroff at the hypervisor.
              Use only when a guest is wedged — it can corrupt etcd.
  --wait      wait for each server to reach the expected power state
  --yes       do not ask for confirmation
  -h, --help  this text

Server names may be given as bare hostnames (master01) or FQDNs.
With no names, every server in the cluster domain is targeted.

Ordering is quorum-safe: shutdown stops workers first then masters,
poweron brings masters up first then workers.

Note: a reboot/shutdown is a request to the guest OS. Hetzner reports a
server as "running" for the whole of an ACPI reboot, so --wait on reboot
waits for the API action, not for the OS to come back. Check the cluster
itself for that: oc get nodes
USAGE
}

ACTION=""
ROLE=all
HARD=0
WAIT=0
ASSUME_YES=0
NAMES=()

[ $# -gt 0 ] || { usage; exit 1; }
case "$1" in
  reboot|shutdown|poweron|status) ACTION=$1; shift ;;
  -h|--help) usage; exit 0 ;;
  *) err "unknown action: $1 (expected reboot, shutdown, poweron or status)" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE=${2:?--role needs a value}; shift 2 ;;
    --hard) HARD=1; shift ;;
    --wait) WAIT=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) err "unknown option: $1" ;;
    *) NAMES+=("$1"); shift ;;
  esac
done

case "$ROLE" in
  master|worker|bootstrap|ignition|all) ;;
  *) err "unknown role: $ROLE" ;;
esac

command -v jq >/dev/null || err "jq is required"
[ -f .env ] || err ".env not found"
export $(grep -v '^#' .env | xargs)
: "${HCLOUD_TOKEN:?HCLOUD_TOKEN missing from .env}"
DOMAIN=${TF_VAR_dns_domain:?TF_VAR_dns_domain missing from .env}

HCAPI="https://api.hetzner.cloud/v1"
_hc() {  # _hc <METHOD> <path>
  curl -s -X "$1" -H "Authorization: Bearer $HCLOUD_TOKEN" "$HCAPI$2"
}

# ── select the target servers ─────────────────────────────────────────────
ALL_JSON=$(_hc GET "/servers?per_page=100")
echo "$ALL_JSON" | jq -e '.servers' >/dev/null 2>&1 \
  || err "Hetzner API error: $(echo "$ALL_JSON" | jq -r '.error.message // .' 2>/dev/null)"

# name<TAB>id<TAB>status, cluster domain only, ordered workers -> masters so a
# shutdown drains the compute nodes before the control plane goes away
SERVERS=$(echo "$ALL_JSON" | jq -r --arg d ".$DOMAIN" '
  .servers[] | select(.name | endswith($d))
  | [.name, (.id|tostring), .status] | @tsv' | sort)

[ -n "$SERVERS" ] || err "no servers found in domain $DOMAIN"

if [ "$ROLE" != all ]; then
  SERVERS=$(echo "$SERVERS" | grep "^$ROLE" || true)
  [ -n "$SERVERS" ] || err "no servers with role '$ROLE'"
fi

if [ ${#NAMES[@]} -gt 0 ]; then
  PAT=$(printf '%s\n' "${NAMES[@]}" | sed "s/\.$DOMAIN\$//" | paste -sd'|' -)
  SERVERS=$(echo "$SERVERS" | grep -E "^($PAT)\." || true)
  [ -n "$SERVERS" ] || err "none of the named servers exist in $DOMAIN"
fi

# masters last on the way down, first on the way up
WORKERS=$(echo "$SERVERS" | grep -v '^master' || true)
MASTERS=$(echo "$SERVERS" | grep    '^master' || true)
case "$ACTION" in
  shutdown) ORDERED=$(printf '%s\n%s\n' "$WORKERS" "$MASTERS" | grep -v '^$' || true) ;;
  poweron)  ORDERED=$(printf '%s\n%s\n' "$MASTERS" "$WORKERS" | grep -v '^$' || true) ;;
  *)        ORDERED=$SERVERS ;;
esac

# ── status is read-only, print and leave ──────────────────────────────────
if [ "$ACTION" = status ]; then
  printf '%-40s %-12s %-10s %s\n' NAME STATE TYPE IPv4
  echo "$ALL_JSON" | jq -r --arg d ".$DOMAIN" '
    .servers[] | select(.name | endswith($d))
    | [.name, .status, .server_type.name,
       (.public_net.ipv4.ip // "-")] | @tsv' | sort \
    | while IFS=$'\t' read -r n s t ip; do
        printf '%-40s %-12s %-10s %s\n' "$n" "$s" "$t" "$ip"
      done
  exit 0
fi

# ── confirm ───────────────────────────────────────────────────────────────
COUNT=$(echo "$ORDERED" | wc -l | tr -d ' ')
log "$ACTION ($([ "$HARD" = 1 ] && echo hard || echo graceful)) — $COUNT server(s)"
echo "$ORDERED" | awk -F'\t' '{printf "    %-40s %s\n", $1, $3}'

if [ "$ASSUME_YES" = 0 ]; then
  printf '\nProceed? [y/N]: '
  read -r ANS
  [ "$ANS" = y ] || [ "$ANS" = Y ] || { echo "aborted"; exit 1; }
fi

# ── the API endpoint for each action ──────────────────────────────────────
case "$ACTION" in
  reboot)   EP=$([ "$HARD" = 1 ] && echo reset    || echo reboot);   WANT=running ;;
  shutdown) EP=$([ "$HARD" = 1 ] && echo poweroff || echo shutdown); WANT=off ;;
  poweron)  EP=poweron;                                              WANT=running ;;
esac

RC=0
while IFS=$'\t' read -r name id state; do
  [ -n "$name" ] || continue
  RESP=$(curl -s -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
           "$HCAPI/servers/$id/actions/$EP")
  AID=$(echo "$RESP" | jq -r '.action.id // empty')
  if [ -z "$AID" ]; then
    printf '  %-40s FAILED: %s\n' "$name" \
      "$(echo "$RESP" | jq -r '.error.message // .' 2>/dev/null)"
    RC=1; continue
  fi
  printf '  %-40s %s requested\n' "$name" "$EP"

  [ "$WAIT" = 1 ] || continue
  # reboot never leaves the "running" state, so there we wait on the action
  if [ "$ACTION" = reboot ]; then
    t=0
    while [ $t -lt 120 ]; do
      st=$(_hc GET "/actions/$AID" | jq -r '.action.status')
      [ "$st" = running ] || break
      sleep 5; t=$((t+5))
    done
    printf '  %-40s action %s\n' "$name" "${st:-unknown}"
  else
    t=0
    while [ $t -lt 180 ]; do
      st=$(_hc GET "/servers/$id" | jq -r '.server.status')
      [ "$st" = "$WANT" ] && break
      sleep 5; t=$((t+5))
    done
    if [ "${st:-}" = "$WANT" ]; then
      printf '  %-40s now %s\n' "$name" "$st"
    else
      printf '  %-40s still %s after 180s\n' "$name" "${st:-unknown}"
      RC=1
    fi
  fi
done <<< "$ORDERED"

if [ "$ACTION" = reboot ]; then
  echo
  echo "    Hetzner reports a server as 'running' throughout an ACPI reboot."
  echo "    Watch the cluster to see the nodes actually return:"
  echo "      export KUBECONFIG=$PWD/ignition/auth/kubeconfig && oc get nodes -w"
fi

exit $RC
