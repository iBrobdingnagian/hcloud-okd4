#!/usr/bin/env bash
# Read-only menu until a teardown mode is selected and separately confirmed.
choose_destroy_action() {
  DESTROY_ACTION=destroy
  local choice
  while :; do
    printf '\nDestroy options — %s (%s)\n' "$DOMAIN" "${DEPLOYMENT_TYPE:-okd}"
    echo '  1) Snapshot current cluster, then destroy (recommended for later restore)'
    echo '  2) Destroy without a new snapshot (keep existing snapshots)'
    echo '  3) List local snapshot sets (read-only)'
    echo '  4) Inspect Hetzner snapshots and local recording status (read-only)'
    echo '  0) Cancel'
    printf 'Selection [0]: '
    if ! read -r choice; then choice=0; fi
    case "${choice:-0}" in
      1)
        SNAPSHOT_BEFORE_DESTROY=1
        echo 'A completed cold snapshot is required before teardown. Images, local restore bundles and original Primary IPs must be retained.'
        echo 'Snapshots and retained Primary IPs remain billable. Nodes will be stopped during capture.'
        return 0 ;;
      2)
        SNAPSHOT_BEFORE_DESTROY=0
        echo 'No new recovery point will be created. Existing images and bundles are kept.'
        echo 'Existing snapshots require their original retained Primary IPs; an image alone is insufficient.'
        return 0 ;;
      3) python3 "$REPO_ROOT/scripts/cluster_snapshot.py" list || return 1 ;;
      4) python3 "$REPO_ROOT/scripts/cluster_snapshot.py" discover || return 1 ;;
      0) DESTROY_ACTION=cancel; echo 'Cancelled. No teardown started.'; return 0 ;;
      *) echo 'Choose 1, 2, 3, 4 or 0.' ;;
    esac
  done
}
