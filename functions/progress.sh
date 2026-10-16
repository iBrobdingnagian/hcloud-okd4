#!/usr/bin/env bash
# functions/progress.sh — live progress page for deploy/destroy runs
# Sourced by deploy-okd.sh and destroy-okd.sh; not meant to be executed directly.
#
# start_progress_server starts scripts/progress_server.py (detached, outlives the
# run) unless THIS checkout's server already runs. One server covers all clusters
# of the checkout: it follows whichever workspace has a deploy/destroy running.
# A server from another checkout (same code, same port) is never reused — it
# would show that repository's runs — so ours moves to the next free port.
# PROGRESS_SERVER=0 disables it; PROGRESS_BIND=127.0.0.1 keeps it local.

PROGRESS_PORT=${PROGRESS_PORT:-8094}

start_progress_server() {
  [ "${PROGRESS_SERVER:-1}" = 0 ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local plan
  plan=$(python3 "$REPO_ROOT/scripts/progress_server.py" --plan-port --port "$PROGRESS_PORT" 2>/dev/null) \
    || { echo "    (progress page unavailable: no free port from $PROGRESS_PORT)"; return 0; }
  PROGRESS_PORT=${plan#* }
  if [ "${plan%% *}" = start ]; then
    mkdir -p "$REPO_ROOT/logs"
    python3 - "$REPO_ROOT" "$PROGRESS_PORT" "${PROGRESS_BIND:-0.0.0.0}" <<'PY'
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
with (root / 'logs/progress-server.log').open('ab') as log:
    subprocess.Popen(
        [sys.executable, str(root / 'scripts/progress_server.py'),
         '--port', sys.argv[2], '--bind', sys.argv[3]],
        stdin=subprocess.DEVNULL, stdout=log, stderr=log,
        start_new_session=True,
    )
PY
  fi
  local host
  host=$(hostname -I 2>/dev/null | awk '{print $1}') || host=""
  printf '\033[0;36m    live progress: http://%s:%s/\033[0m\n' "${host:-localhost}" "$PROGRESS_PORT"
  printf '\033[0;36m    deploy / destroy controls: http://%s:%s/manage\033[0m\n' "${host:-localhost}" "$PROGRESS_PORT"
  printf '    control token (on this host): %s/logs/progress-control-token\n' "$REPO_ROOT"
}

# progress_step <operation> <title> <typical duration> — current step for the
# progress page (title and timing only, never secrets)
progress_step() {
  mkdir -p logs
  jq -n --arg op "$1" --arg title "$2" --arg typical "$3" \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{op:$op, title:$title, typical:$typical, at:$at}' \
    > logs/current-step.json 2>/dev/null || true
}
