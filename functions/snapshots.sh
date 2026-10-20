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
  # Repair the actual user kubeconfig, including an old LB IP saved in a snapshot.
  # Keep the original CA/credentials and verify the cluster's DNS name over TLS.
  python3 "$REPO_ROOT/scripts/cluster_access.py" refresh "$PWD" "$DOMAIN" \
    || err "could not configure restored CLI access"
  configure_host_api
  # Bypass the shell oc wrapper: success must prove the user's kubeconfig works
  # without private --server overrides or a functioning workstation DNS cache.
  local -a health_oc=(command oc --request-timeout=15s)
  log "Waiting for the restored API, nodes and operators (up to 30 minutes)"
  local ready=0 deadline=$((SECONDS + 1800))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "${health_oc[@]}" get --raw=/readyz >/dev/null 2>&1 \
      && "${health_oc[@]}" get nodes -o json | jq -e \
        --argjson total "$((TF_VAR_replicas_master + TF_VAR_replicas_worker))" \
        '.items | (length == $total) and all(.[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))' >/dev/null 2>&1 \
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
  printf 'CLI: export KUBECONFIG="%s"\n     oc get nodes\n' "$KUBECONFIG"
  printf 'Console: https://console-openshift-console.apps.%s\n%s\n' "$DOMAIN" "$AUTODESTROY_NOTE"
}
