#!/usr/bin/env bash
# Checkpoints record completed phases, never permission to skip health checks.
phase_done() { [ -f ".phases/$1" ]; }
phase_mark() {
  mkdir -p .phases
  date -u '+%Y-%m-%dT%H:%M:%SZ' > ".phases/$1.tmp"
  mv ".phases/$1.tmp" ".phases/$1"
  printf '  phase %-20s complete\n' "$1"
}

validate_ignition() {
  [ -s ignition/auth/kubeconfig ] || err "missing ignition/auth/kubeconfig; refusing to regenerate credentials"
  local role
  for role in bootstrap master worker; do
    [ -s "ignition/$role.ign" ] || err "missing ignition/$role.ign; inspect the incomplete installation before resuming"
  done
  assert_cluster_context || err "installer kubeconfig belongs to a different cluster"
  python3 "$REPO_ROOT/scripts/validate_ignition.py" ignition/*.ign
}

verify_cluster_health() {
  oc get --raw=/readyz >/dev/null || err "cluster API is not ready"
  oc get clusteroperators -o json | jq -e '
    (.items | length > 0) and all(.items[];
      any(.status.conditions[]; .type == "Available" and .status == "True") and
      all(.status.conditions[]; (.type != "Degraded" and .type != "Progressing") or .status == "False"))
  ' >/dev/null || err "cluster operators are unavailable, degraded, or progressing; use --resume after resolving them"
}

infrastructure_plan() {
  [ -s ignition/auth/kubeconfig ] && [ -n "${TF_VAR_fcos_release:-}" ] \
    || err "a Terraform resource diff needs existing ignition and a resolved CoreOS image; use --cluster NAME --plan for a new cluster"
  command -v docker >/dev/null || err "docker is required for --terraform-plan"
  docker info >/dev/null 2>&1 || err "start Docker before requesting a Terraform resource diff"
  TOOLBOX=quay.io/slauger/hcloud-okd4:$OPENSHIFT_RELEASE
  docker image inspect "$TOOLBOX" >/dev/null 2>&1 || err "toolbox image is unavailable; build it before requesting a Terraform resource diff"
  local bootstrap=true
  phase_done bootstrap-complete && bootstrap=false
  # Legacy installations have no checkpoints; preserve the bootstrap state recorded by Terraform.
  if ! phase_done configured; then
    bootstrap=$(python3 - <<'PY'
import json
from pathlib import Path
p = Path('terraform/terraform.tfstate')
if not p.exists():
    raise SystemExit('No local state/checkpoints; cannot determine bootstrap intent safely')
d = json.loads(p.read_text())
print(str(any(r.get('module') == 'module.bootstrap' and r.get('type') == 'hcloud_server' and r.get('instances') for r in d.get('resources', []))).lower())
PY
    ) || return 1
  fi
  # Explicit flags are validated before passing values to Make/Terraform.
  local key value vars=""
  for key in masters workers master-type worker-type; do
    case "$key" in
      masters) value=$FLAG_MASTERS; key=replicas_master ;;
      workers) value=$FLAG_WORKERS; key=replicas_worker ;;
      master-type) value=$FLAG_MASTER_TYPE; key=server_type_master ;;
      worker-type) value=$FLAG_WORKER_TYPE; key=server_type_worker ;;
    esac
    if [ -n "$value" ]; then
      [[ "$value" =~ ^[a-z0-9]+$ ]] || err "invalid plan value for $key"
      vars="$vars -var=$key=$value"
    fi
  done
  tb "make infrastructure MODE='plan$vars' BOOTSTRAP=$bootstrap"
}

# All pages, with HTTP and response-shape checks. Failure is never an empty fleet.
hcloud_list() {
  local resource=$1 page=1 response next all='[]'
  while :; do
    response=$(curl -fsS --connect-timeout 10 --max-time 60 \
      -H "Authorization: Bearer $HCLOUD_TOKEN" \
      "https://api.hetzner.cloud/v1/$resource?per_page=100&page=$page") || return 1
    echo "$response" | jq -e --arg r "$resource" '.[$r] | type == "array"' >/dev/null \
      || { echo "Invalid Hetzner $resource response" >&2; return 1; }
    all=$(jq -cn --argjson a "$all" --argjson b "$response" --arg r "$resource" '$a + $b[$r]')
    next=$(echo "$response" | jq -r '.meta.pagination.next_page // empty')
    [ -n "$next" ] || break
    [[ "$next" =~ ^[0-9]+$ ]] && [ "$next" -gt "$page" ] || return 1
    page=$next
  done
  jq -cn --arg r "$resource" --argjson a "$all" '{($r): $a}'
}

cluster_servers() {
  hcloud_list servers | jq -e --arg d ".$DOMAIN" --arg id "${CLUSTER_ID:-}" '
    if $id != "" and any(.servers[];
      (.labels["hcloud-okd4/cluster"] == $id and (.name | endswith($d) | not)) or
      ((.name | endswith($d)) and .labels["hcloud-okd4/cluster"] != $id and
       .labels["hcloud/node-group"] != ("worker-asc-" + $id)))
    then error("cluster name/domain conflicts with existing resources") else
    {servers: [.servers[] | select(
      if $id == "" then (.name | endswith($d))
      else (.labels["hcloud-okd4/cluster"] == $id or
            .labels["hcloud/node-group"] == ("worker-asc-" + $id)) end)]} end'
}

validate_deploy_flags() {
  local value
  for value in "$FLAG_MASTERS" "$FLAG_WORKERS"; do
    [ -z "$value" ] || [[ "$value" =~ ^[0-9]+$ ]] || err "replica counts must be nonnegative integers"
  done
  [ -z "$FLAG_MASTERS" ] || [[ "$FLAG_MASTERS" =~ ^(1|3|5)$ ]] || err "master count must be 1, 3, or 5"
  for value in "$FLAG_REGION" "$FLAG_MASTER_TYPE" "$FLAG_WORKER_TYPE"; do
    [ -z "$value" ] || [[ "$value" =~ ^[a-z0-9-]+$ ]] || err "invalid region or server type"
  done
  [ -z "$FLAG_RELEASE" ] || [[ "$FLAG_RELEASE" =~ ^[0-9]+\.[0-9]+[a-zA-Z0-9_.-]*$ ]] || err "invalid release tag"
  for value in "$FLAG_DURATION" "$FLAG_AUTODESTROY_AT"; do
    [ -z "$value" ] || [[ "$value" =~ ^[1-9][0-9]*m?$ ]] || err "duration must be positive hours or minutes (e.g. 8 or 90m)"
  done
}

assert_cluster_context() {
  local server
  server=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}') || return 1
  [ "$server" = "https://api.$DOMAIN:6443" ] \
    || { echo "Kubeconfig does not belong to $DOMAIN; refusing operation" >&2; return 1; }
}

drain_node() {
  oc adm cordon "$1" || return 1
  if ! oc adm drain "$1" --ignore-daemonsets --delete-emptydir-data --timeout=180s; then
    echo "Drain failed for $1; leaving it cordoned and preserving its VM. Resolve blocked workloads before retrying." >&2
    return 1
  fi
}

etcd_endpoints_healthy() {
  oc -n openshift-etcd exec "$1" -c etcdctl -- etcdctl endpoint health --cluster -w json \
    | jq -e 'length > 0 and all(.[]; .health == true)' >/dev/null \
    || { echo "etcd endpoint health failed; stopping control-plane change" >&2; return 1; }
}

ca_node_ids() {
  hcloud_list servers | jq -r --arg net "${CA_NETID:-}" --arg id "${CLUSTER_ID:-}" '
    .servers[]
    | select(.labels["hcloud/node-group"] != null)
    | select(if $id != "" then .labels["hcloud/node-group"] == ("worker-asc-" + $id)
             else ($net != "" and ([.private_net[]?.network | tostring] | index($net))) end)
    | "\(.id) \(.name)"'
}

stop_cluster_autoscaler_before_destroy() {
  local deployment
  if deployment=$(oc -n cluster-autoscaler get deployment cluster-autoscaler --ignore-not-found -o name 2>&1); then
    [ -n "$deployment" ] || return 0
    oc -n cluster-autoscaler scale deployment/cluster-autoscaler --replicas=0 || return 1
    oc -n cluster-autoscaler wait --for=delete pod -l app=cluster-autoscaler --timeout=120s || return 1
    return 0
  fi

  case "$deployment" in
    *"no such host"*|*"connection refused"*|*"i/o timeout"*|*"context deadline exceeded"*|*"network is unreachable"*)
      echo "Cluster API is unreachable; continuing with Hetzner autoscaler-node cleanup" >&2
      return 0
      ;;
    *)
      printf '%s\n' "$deployment" >&2
      return 1
      ;;
  esac
}

run_addon() {
  local before=${DEVOPS_NOTE:-} result=0
  "$@" || result=$?
  # Some legacy installers report a failed dependency in DEVOPS_NOTE.
  if [ "$result" = 0 ] && [ "${DEVOPS_NOTE:-}" != "$before" ]; then
    case "${DEVOPS_NOTE#"$before"}" in *FAILED*|*failed*) result=1 ;; esac
  fi
  if [ "$result" = 0 ]; then printf '  addon %-30s completed\n' "$*"
  else printf '  addon %-30s FAILED\n' "$*" >&2; fi
  return "$result"
}
