#!/usr/bin/env bash
# Shared entry point. The Python parent holds the operation lock until exit,
# independently of EXIT traps in the deployment helpers.
cluster_dispatch() {
  local operation=$1
  shift
  if [ -z "${HCLOUD_OKD4_CONTEXT_DIR:-}" ]; then
    exec python3 "$REPO_ROOT/scripts/cluster_context.py" run "$REPO_ROOT" "$operation" "$@"
  fi
  cd "$HCLOUD_OKD4_CONTEXT_DIR" || exit 1
}

load_env() {
  local rendered
  rendered=$(python3 "$REPO_ROOT/scripts/cluster_context.py" env .env) || return 1
  # Only validated, shell-quoted assignments produced by our parser are evaluated.
  eval "$rendered"
}
