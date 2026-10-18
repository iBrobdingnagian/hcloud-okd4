#!/usr/bin/env bash
# Cold node snapshots retain original Primary IPs and installer identity.

snapshot_before_destroy() {
  command -v oc >/dev/null || err "oc is required to verify the cluster before snapshotting"
  assert_cluster_context || err "snapshot kubeconfig belongs to another cluster"
  verify_cluster_health
  # A running resident autoscaler could provision nodes during shutdown.
  # Require the operator to disable it explicitly; do not mutate the saved workload.
  local replicas
  replicas=$(oc --request-timeout=15s -n cluster-autoscaler get deployment cluster-autoscaler \
    --ignore-not-found -o jsonpath='{.spec.replicas}') || err "could not verify autoscaler status"
  [ -z "$replicas" ] || [ "$replicas" = 0 ] \
    || err "disable the resident cluster-autoscaler before snapshotting"
  python3 "$REPO_ROOT/scripts/cluster_snapshot.py" create \
    || err "snapshot failed; infrastructure has NOT been deleted (nodes may be stopped)"
}

restore_cluster_snapshot() {
  local arg skip=0
  for arg in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$arg" in
      --restore-snapshot|--duration|--autodestroy-at) skip=1 ;;
      --yes|--no-autodestroy|--snapshot-before-destroy|--no-snapshot-before-destroy) ;;
      *) err "--restore-snapshot uses saved configuration; incompatible option: $arg" ;;
    esac
  done
  command -v docker >/dev/null || err "docker is required for snapshot restore"
  command -v oc >/dev/null || err "oc is required for snapshot restore health checks"
  command -v jq >/dev/null || err "jq is required for snapshot restore health checks"
  docker info >/dev/null 2>&1 || err "start Docker before restoring"
  TOOLBOX=quay.io/slauger/hcloud-okd4:$OPENSHIFT_RELEASE
  docker image inspect "$TOOLBOX" >/dev/null 2>&1 || err "restore requires the original toolbox image: $TOOLBOX"
  if [ "$ASSUME_YES" != 1 ]; then
    printf '\nRestore snapshot %s for %s? This provisions billable servers. Type "restore": ' "$FLAG_RESTORE_SNAPSHOT" "$DOMAIN"
    local confirm
    read -r confirm
    [ "$confirm" = restore ] || { echo "Aborted."; return 0; }
  fi
  python3 "$REPO_ROOT/scripts/cluster_snapshot.py" prepare-restore "$FLAG_RESTORE_SNAPSHOT"
  load_env
  export KUBECONFIG="$PWD/ignition/auth/kubeconfig"
  log "Restoring node disks and original IPs from $FLAG_RESTORE_SNAPSHOT"
  progress_step deploy "Restoring cluster snapshots" "5-15 min"
  # Infrastructure only: no installer, Packer, Ansible or ignition regeneration.
  tb "make infrastructure MODE='apply -auto-approve' BOOTSTRAP=false"
  # A local resolver may cache NXDOMAIN from the period after teardown. Use the
  # managed LB address for checks while retaining normal hostname verification.
  # The saved user kubeconfig and cluster's DNS names are never rewritten.
  local lb_ip
  lb_ip=$(python3 - "$DOMAIN" <<'PY'
import ipaddress, json, sys
from pathlib import Path
state = json.loads(Path('terraform/terraform.tfstate').read_text())
addresses = [i['attributes']['ipv4'] for r in state['resources']
             if r.get('mode') != 'data' and r['type'] == 'hcloud_load_balancer'
             for i in r.get('instances', [])
             if i['attributes'].get('name') == 'lb.' + sys.argv[1]]
if len(addresses) != 1:
    raise SystemExit('Cannot identify the restored cluster load balancer')
print(ipaddress.IPv4Address(addresses[0]))
PY
  ) || return 1
  local -a health_oc=(oc --request-timeout=15s "--server=https://$lb_ip:6443" "--tls-server-name=api.$DOMAIN")
  log "Waiting for the restored API, nodes and operators (up to 30 minutes)"
  local ready=0 deadline=$((SECONDS + 1800))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "${health_oc[@]}" get --raw=/readyz >/dev/null 2>&1 \
      && "${health_oc[@]}" get nodes -o json | jq -e \
        --argjson total "$((TF_VAR_replicas_master + TF_VAR_replicas_worker))" \
        '.items | length == $total and all(.[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))' >/dev/null 2>&1 \
      && "${health_oc[@]}" get clusteroperators -o json | jq -e \
        '.items | length > 0 and all(.[];
          any(.status.conditions[]; .type == "Available" and .status == "True") and
          all(.status.conditions[]; (.type != "Degraded" and .type != "Progressing") or .status == "False"))' >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 15
  done
  [ "$ready" = 1 ] || err "restored infrastructure exists but health checks failed; inspect it, then retry --restore-snapshot $FLAG_RESTORE_SNAPSHOT"
  phase_mark configured
  phase_mark bootstrap-complete
  phase_mark ready
  python3 - "$FLAG_RESTORE_SNAPSHOT" <<'PY'
import json, sys
from pathlib import Path
Path('logs/restore-snapshot.json').write_text(json.dumps({'id': sys.argv[1], 'status': 'restored'}) + '\n')
PY
  DUR=${FLAG_DURATION:-${LAB_DURATION:-8}}
  schedule_autodestroy
  log "Snapshot $FLAG_RESTORE_SNAPSHOT restored successfully"
  printf 'Console: https://console-openshift-console.apps.%s\n%s\n' "$DOMAIN" "$AUTODESTROY_NOTE"
}
