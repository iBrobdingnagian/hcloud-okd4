#!/usr/bin/env bash
# functions/rescale.sh — in-place CPU/RAM rescale of cluster VMs WITHOUT
# destroying the cluster (e.g. cx33 -> cx43). Hetzner supports changing a
# server's type while keeping its disk; the server must be powered off for the
# change. To keep the cluster serving we do it ROLLING, one node at a time:
#   cordon+drain -> power off -> change_type (keep disk) -> power on
#   -> wait Ready -> uncordon  (masters one-by-one so etcd quorum is preserved)
#
# We change the type via the Hetzner API rather than terraform because a
# terraform apply would power off ALL nodes of a role in parallel (all masters
# down at once = etcd outage). The .env TF_VAR_server_type_* is updated at the
# end so terraform reconciles on its next (refresh-on) apply — reality already
# matches, so it's a no-op.
#
# Sourced by deploy-okd.sh; not meant to be executed directly.

HCAPI="https://api.hetzner.cloud/v1"
_hc() {  # _hc <METHOD> <path> [json-body]
  local m=$1 p=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -s -X "$m" -H "Authorization: Bearer $HCLOUD_TOKEN" \
      -H 'Content-Type: application/json' -d "$body" "$HCAPI$p"
  else
    curl -s -X "$m" -H "Authorization: Bearer $HCLOUD_TOKEN" "$HCAPI$p"
  fi
}
_wait_srv_status() {  # <id> <wanted-status> <timeout_s>
  local id=$1 want=$2 to=${3:-180} t=0 st
  while [ "$t" -lt "$to" ]; do
    st=$(_hc GET "/servers/$id" | jq -r '.server.status' 2>/dev/null)
    [ "$st" = "$want" ] && return 0
    sleep 5; t=$((t+5))
  done
  return 1
}
_wait_action() {  # <action-id> <timeout_s>
  local aid=$1 to=${2:-600} t=0 st
  [ -n "$aid" ] && [ "$aid" != "null" ] || return 1
  while [ "$t" -lt "$to" ]; do
    st=$(_hc GET "/actions/$aid" | jq -r '.action.status' 2>/dev/null)
    case "$st" in success) return 0;; error) return 1;; esac
    sleep 5; t=$((t+5))
  done
  return 1
}
# wait for the (rebooted) node to report Ready again, approving CSRs meanwhile
_wait_node_ready() {  # <node> <timeout_s>
  # the node is still cordoned here, so `oc get node` prints
  # "Ready,SchedulingDisabled" — check the Ready CONDITION instead of the
  # STATUS column so cordoned-but-Ready counts as ready.
  local node=$1 to=${2:-360} t=0 st
  while [ "$t" -lt "$to" ]; do
    oc get csr -o name 2>/dev/null | xargs -r oc adm certificate approve >/dev/null 2>&1 || true
    st=$(oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [ "$st" = "True" ] && return 0
    sleep 10; t=$((t+10))
  done
  return 1
}
# wait until etcd is healthy again: all control-plane etcd pods Running and the
# operator no longer Progressing (best-effort)
_wait_etcd_healthy() {  # <expected-members> <timeout_s>
  local want=$1 to=${2:-420} t=0 running prog
  while [ "$t" -lt "$to" ]; do
    running=$(oc -n openshift-etcd get pods -l app=etcd --no-headers 2>/dev/null \
      | awk '$2 ~ /^([0-9]+)\/\1$/ && $3=="Running"' | wc -l | tr -d ' ')
    prog=$(oc get etcd cluster -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.status}{end}' 2>/dev/null)
    [ "${running:-0}" -ge "$want" ] && [ "$prog" != "True" ] && return 0
    sleep 10; t=$((t+10))
  done
  return 1
}

# run_rescale — rolling in-place server-type change. Reads DOMAIN, HCLOUD_TOKEN,
# ASSUME_YES and FLAG_RESCALE_ROLE / FLAG_RESCALE_TYPE. Always returns (caller
# decides to exit).
run_rescale() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  command -v jq >/dev/null 2>&1 || { err "jq is required for --rescale"; return 1; }
  [ -n "$HCLOUD_TOKEN" ] || { err "HCLOUD_TOKEN is not set (.env)"; return 1; }
  oc whoami >/dev/null 2>&1 || { echo "    cannot reach the cluster — is it running?"; return 1; }

  # ── which role(s) ─────────────────────────────────────────────────────
  local role=${FLAG_RESCALE_ROLE:-} newtype=${FLAG_RESCALE_TYPE:-}
  if [ -z "$role" ]; then
    if [ "$ASSUME_YES" = 1 ]; then
      err "--rescale needs --rescale-role (master|worker|all) in non-interactive mode"; return 1
    fi
    echo
    echo "Which nodes do you want to rescale (change CPU/RAM)?"
    echo "  1) workers"
    echo "  2) masters  (rolling, one at a time — etcd quorum preserved)"
    echo "  3) all"
    printf 'Selection [1]: '; read -r r
    case "${r:-1}" in 1) role=worker;; 2) role=master;; 3) role=all;; *) role=worker;; esac
  fi
  case "$role" in master|worker|all) ;; *) err "invalid role '$role' (master|worker|all)"; return 1;; esac

  # ── target type + validation ──────────────────────────────────────────
  local types_json
  types_json=$(_hc GET "/server_types?per_page=100")
  echo "$types_json" | jq -e '.server_types' >/dev/null 2>&1 \
    || { err "could not fetch Hetzner server types (check HCLOUD_TOKEN)"; return 1; }
  if [ -z "$newtype" ]; then
    if [ "$ASSUME_YES" = 1 ]; then
      err "--rescale needs --rescale-type <server-type> in non-interactive mode"; return 1
    fi
    local loc=${TF_VAR_location:-} cand names n nm c m d pr prtxt sel
    echo
    echo "Available x86 server types${loc:+ — monthly price for $loc} (vCPU / RAM / disk):"
    # x86, non-deprecated, sorted by monthly price; price is for the cluster's
    # location (0 => not offered there, shown as n/a). TAB-separated rows.
    cand=$(echo "$types_json" | jq -r --arg loc "$loc" '
      .server_types[] | select(.architecture=="x86" and .deprecated==false) | . as $t
      | ( [ $t.prices[] | select($loc=="" or .location==$loc) | .price_monthly.gross | tonumber ] | (.[0] // 0) ) as $p
      | [$t.name, ($t.cores|tostring), ($t.memory|tostring), ($t.disk|tostring), (($p*100|round)/100|tostring)]
      | @tsv' | sort -t"$(printf '\t')" -k5 -n)
    n=0; names=""
    while IFS=$'\t' read -r nm c m d pr; do
      [ -n "$nm" ] || continue
      n=$((n+1)); names="$names$nm
"
      if [ "$pr" = "0" ]; then prtxt="    n/a"; else prtxt=$(printf '€%s/mo' "$pr"); fi
      printf '  %2d) %-7s %2s vCPU / %3sGB RAM / %4sGB disk — %s\n' "$n" "$nm" "$c" "$m" "$d" "$prtxt"
    done <<EOF
$cand
EOF
    printf 'New server type (number or name): '; read -r sel
    if printf '%s' "$sel" | grep -qE '^[0-9]+$'; then
      newtype=$(printf '%s' "$names" | sed -n "${sel}p")
    else
      newtype=$sel
    fi
    [ -n "$newtype" ] || { err "no server type selected"; return 1; }
  fi
  local tcores tmem tdisk
  tcores=$(echo "$types_json" | jq -r --arg t "$newtype" '.server_types[]|select(.name==$t)|.cores' | head -1)
  tmem=$(echo "$types_json"   | jq -r --arg t "$newtype" '.server_types[]|select(.name==$t)|.memory' | head -1)
  tdisk=$(echo "$types_json"  | jq -r --arg t "$newtype" '.server_types[]|select(.name==$t)|.disk' | head -1)
  [ -n "$tcores" ] && [ "$tcores" != "null" ] || { err "unknown server type '$newtype'"; return 1; }

  # ── build the ordered node list from the live Hetzner inventory ────────
  local srv_json prefixes p
  srv_json=$(_hc GET "/servers?per_page=100")
  case "$role" in master) prefixes="master";; worker) prefixes="worker";; all) prefixes="master worker";; esac
  local plan=""   # lines: "<name> <id> <curtype> <curdisk>"
  for p in $prefixes; do
    while IFS=$'\t' read -r nm id ct cd; do
      [ -n "$nm" ] && plan="$plan$nm	$id	$ct	$cd
"
    done < <(echo "$srv_json" | jq -r --arg d "$DOMAIN" --arg p "$p" \
      '.servers[] | select(.name | test("^" + $p + "[0-9]+\\." + $d))
       | [.name, (.id|tostring), .server_type.name, (.primary_disk_size|tostring)] | @tsv' | sort)
  done
  [ -n "$(echo "$plan" | tr -d '[:space:]')" ] || { err "no $role server(s) found for $DOMAIN"; return 1; }

  # ── show the plan & confirm ───────────────────────────────────────────
  log "Rescale plan — role: $role  ->  $newtype ($tcores vCPU / ${tmem}GB RAM / ${tdisk}GB disk)"
  local any=0 line nm id ct cd
  while IFS=$'\t' read -r nm id ct cd; do
    [ -n "$nm" ] || continue
    if [ "$ct" = "$newtype" ]; then
      echo "    $nm: already $newtype — will skip"
    elif [ "${cd:-0}" -gt "${tdisk:-0}" ]; then
      echo "    $nm: $ct (disk ${cd}GB) -> $newtype (disk ${tdisk}GB) — SKIP: target disk is smaller (keep-disk impossible)"
    else
      echo "    $nm: $ct -> $newtype"; any=1
    fi
  done <<EOF
$plan
EOF
  [ "$any" = 1 ] || { log "Nothing to rescale (all targets already $newtype or incompatible)"; return 0; }

  cat <<EOF

  Each node will be: cordoned & drained -> powered off -> changed to $newtype
  (disk kept) -> powered back on -> waited until Ready -> uncordoned.
  Masters are done one at a time so etcd keeps quorum. Expect a few minutes of
  reduced capacity per node; workloads reschedule onto the others.
EOF
  if [ "$ASSUME_YES" = 0 ]; then
    printf 'Proceed with the rolling rescale? [y/N]: '; read -r ok
    [ "$ok" = y ] || [ "$ok" = Y ] || { echo "Aborted."; return 0; }
  fi

  # ── execute, node by node ─────────────────────────────────────────────
  local masters_total
  masters_total=$(echo "$srv_json" | jq -r --arg d "$DOMAIN" \
    '[.servers[]|select(.name|test("^master[0-9]+\\."+$d))]|length')
  while IFS=$'\t' read -r nm id ct cd; do
    [ -n "$nm" ] || continue
    [ "$ct" = "$newtype" ] && continue
    [ "${cd:-0}" -gt "${tdisk:-0}" ] && continue
    local is_master=0; case "$nm" in master*) is_master=1;; esac

    log "Rescaling $nm: $ct -> $newtype"
    echo "    cordon + drain"
    oc adm cordon "$nm" >/dev/null 2>&1 || true
    oc adm drain "$nm" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s >/dev/null 2>&1 \
      || echo "    (drain reported issues — continuing; static control-plane pods are expected to remain)"

    echo "    powering off"
    _wait_action "$(_hc POST "/servers/$id/actions/poweroff" | jq -r '.action.id')" 180 || true
    _wait_srv_status "$id" off 180 || { echo "    WARNING: $nm did not reach 'off' — skipping, leaving it cordoned"; continue; }

    echo "    changing type to $newtype (keeping disk)"
    local resp aid
    resp=$(_hc POST "/servers/$id/actions/change_type" "{\"server_type\":\"$newtype\",\"upgrade_disk\":false}")
    aid=$(echo "$resp" | jq -r '.action.id')
    if [ -z "$aid" ] || [ "$aid" = null ]; then
      echo "    ERROR: change_type rejected: $(echo "$resp" | jq -r '.error.message // .' 2>/dev/null)"
      echo "    powering back on unchanged"
      _hc POST "/servers/$id/actions/poweron" >/dev/null; _wait_srv_status "$id" running 180 || true
      oc adm uncordon "$nm" >/dev/null 2>&1 || true
      continue
    fi
    _wait_action "$aid" 600 || { echo "    WARNING: change_type action did not report success — check the Hetzner console"; }

    echo "    powering on"
    _wait_action "$(_hc POST "/servers/$id/actions/poweron" | jq -r '.action.id')" 180 || true
    _wait_srv_status "$id" running 180 || true

    echo "    waiting for $nm to rejoin as Ready"
    _wait_node_ready "$nm" 420 || echo "    WARNING: $nm not Ready yet — check: oc get nodes / oc get csr"
    oc adm uncordon "$nm" >/dev/null 2>&1 || true

    if [ "$is_master" = 1 ]; then
      echo "    waiting for etcd to be healthy before the next master"
      _wait_etcd_healthy "$masters_total" 420 || echo "    WARNING: etcd not confirmed healthy — verify before continuing: oc get etcd / oc -n openshift-etcd get pods"
    fi
    echo "    $nm is now $newtype and Ready"
  done <<EOF
$plan
EOF

  # ── persist the new type so terraform stays in sync ────────────────────
  case "$role" in
    master) sedi -E "s|^TF_VAR_server_type_master=.*|TF_VAR_server_type_master=$newtype|" .env ;;
    worker) sedi -E "s|^TF_VAR_server_type_worker=.*|TF_VAR_server_type_worker=$newtype|" .env ;;
    all)    sedi -E -e "s|^TF_VAR_server_type_master=.*|TF_VAR_server_type_master=$newtype|" \
                     -e "s|^TF_VAR_server_type_worker=.*|TF_VAR_server_type_worker=$newtype|" .env ;;
  esac

  log "Rescale complete — $role node(s) now $newtype"
  echo "    .env updated (TF_VAR_server_type_$role=$newtype). terraform reconciles on its"
  echo "    next apply: it refreshes state, sees the live type already matches, no change."
  oc get nodes 2>/dev/null
  return 0
}
