#!/usr/bin/env bash
# functions/mixed-sizes.sh — nodes added by --scale / --autoscale can use a
# different VM size than the existing ones.
#
# Terraform reads TF_VAR_server_types_master / _worker: a comma-separated list,
# position i = master0(i+1) / worker0(i+1) (empty = the single server_type_* for
# every node). Existing nodes keep the size they really have (read from the Hetzner
# API) so terraform never resizes them; only the new positions get the new type.
# Sourced by deploy-okd.sh; not meant to be executed directly.

# set KEY=VALUE in .env (replace or append) and in this shell
env_set() {
  local k=$1 v=$2
  if grep -q "^$k=" .env 2>/dev/null; then sedi -E "s|^$k=.*|$k=$v|" .env
  else echo "$k=$v" >> .env; fi
  export "$k=$v"
}

# print the real server type of role01..roleN (one per line); return 1 if any is unknown
_live_node_types() {  # _live_node_types <master|worker> <count>
  local role=$1 n=$2 json i nm t
  [ "$n" -gt 0 ] || return 0
  json=$(curl -s -m 30 -H "Authorization: Bearer $HCLOUD_TOKEN" "https://api.hetzner.cloud/v1/servers?per_page=100")
  echo "$json" | jq -e '.servers' >/dev/null 2>&1 || return 1
  for i in $(seq 1 "$n"); do
    nm=$(printf '%s%02d.%s' "$role" "$i" "$DOMAIN")
    t=$(echo "$json" | jq -r --arg n "$nm" '.servers[] | select(.name==$n) | .server_type.name')
    [ -n "$t" ] || return 1
    echo "$t"
  done
}

# fill CANDIDATES (types placeable in the cluster's location, with prices)
_load_type_candidates() {
  local saved=${FLAG_REGION:-}
  FLAG_REGION=${TF_VAR_location:-nbg1}
  select_region >/dev/null
  FLAG_REGION=$saved
}

# choose_new_node_type <master|worker> <how many new nodes>
# result in NEW_MASTER_TYPE / NEW_WORKER_TYPE (empty = same as the current type)
choose_new_node_type() {
  local role=$1 n=$2 flag cur minc minr ans
  case "$role" in
    master) flag=${FLAG_NEW_MASTER_TYPE:-}; cur=${TF_VAR_server_type_master:-}; minc=4; minr=16 ;;
    worker) flag=${FLAG_NEW_WORKER_TYPE:-}; cur=${TF_VAR_server_type_worker:-}; minc=2; minr=8 ;;
    *) return 1 ;;
  esac
  local chosen=""
  if [ -n "$flag" ]; then
    _load_type_candidates
    pick_type "$role" "$minc" "$minr" "$flag" "" cheapest
    chosen=$PICKED_TYPE
  elif [ "${ASSUME_YES:-0}" = 1 ]; then
    chosen=""
  else
    printf '\nServer type for the %d new %s node(s) [Enter = %s (same as existing), ? = list with prices, or type a name]: ' \
      "$n" "$role" "${cur:-current}"
    read -r ans
    if [ -z "$ans" ]; then chosen=""
    elif [ "$ans" = "?" ]; then
      _load_type_candidates
      pick_type "$role" "$minc" "$minr" "" "" interactive
      chosen=$PICKED_TYPE
    else
      _load_type_candidates
      pick_type "$role" "$minc" "$minr" "$ans" "" cheapest
      chosen=$PICKED_TYPE
    fi
  fi
  case "$role" in master) NEW_MASTER_TYPE=$chosen ;; worker) NEW_WORKER_TYPE=$chosen ;; esac
  [ -n "$chosen" ] && [ "$chosen" != "$cur" ] && echo "    new $role node(s) will be $chosen (existing: ${cur:-unchanged})"
  return 0
}

# plan_node_types — before terraform: write TF_VAR_server_types_* for the new counts.
# Reads CUR_MASTERS/CUR_WORKERS/NEW_MASTERS/NEW_WORKERS (+ NEW_*_TYPE / FLAG_NEW_*_TYPE).
plan_node_types() {
  local role cur new base newtype keep i live list uniform t
  for role in master worker; do
    case "$role" in
      master) cur=$CUR_MASTERS new=$NEW_MASTERS base=${TF_VAR_server_type_master:-}
              newtype=${NEW_MASTER_TYPE:-${FLAG_NEW_MASTER_TYPE:-}} ;;
      worker) cur=$CUR_WORKERS new=$NEW_WORKERS base=${TF_VAR_server_type_worker:-}
              newtype=${NEW_WORKER_TYPE:-${FLAG_NEW_WORKER_TYPE:-}} ;;
    esac
    [ "$new" -ne "$cur" ] || continue
    [ -n "$newtype" ] || newtype=$base
    keep=$cur; [ "$new" -lt "$keep" ] && keep=$new
    live=$(_live_node_types "$role" "$keep") \
      || { printf '\033[1;31mERROR: cannot read the current size of the existing %ss from Hetzner — refusing to plan node sizes (terraform could resize them)\033[0m\n' "$role" >&2; return 1; }
    list="" uniform=1
    for t in $live; do
      list="${list:+$list,}$t"; [ "$t" = "$base" ] || uniform=0
    done
    i=$((keep + 1))
    while [ "$i" -le "$new" ]; do
      list="${list:+$list,}$newtype"; [ "$newtype" = "$base" ] || uniform=0
      i=$((i + 1))
    done
    [ "$uniform" = 1 ] && list=""      # everything equals server_type_* -> keep .env simple
    env_set "TF_VAR_server_types_$role" "$list"
    [ -n "$list" ] && echo "    ${role} sizes: $list"
  done
  return 0
}
