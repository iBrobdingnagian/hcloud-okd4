#!/usr/bin/env bash
# functions/progress.sh — live progress page for deploy/destroy runs
# Sourced by deploy-okd.sh and destroy-okd.sh; not meant to be executed directly.
#
# start_progress_server starts scripts/progress_server.py (detached, outlives the
# run) unless something already listens on PROGRESS_PORT. One server covers all
# clusters: it follows whichever workspace has a deploy/destroy running.
# PROGRESS_SERVER=0 disables it; PROGRESS_BIND=127.0.0.1 keeps it local.

PROGRESS_PORT=${PROGRESS_PORT:-8093}

start_progress_server() {
  [ "${PROGRESS_SERVER:-1}" = 0 ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  if ! python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', $PROGRESS_PORT), 1)" 2>/dev/null; then
    mkdir -p "$REPO_ROOT/logs"
    nohup setsid python3 "$REPO_ROOT/scripts/progress_server.py" \
      --port "$PROGRESS_PORT" --bind "${PROGRESS_BIND:-0.0.0.0}" \
      >"$REPO_ROOT/logs/progress-server.log" 2>&1 </dev/null &
  fi
  local host
  host=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '\033[0;36m    live progress: http://%s:%s/\033[0m\n' "${host:-localhost}" "$PROGRESS_PORT"
}

# progress_step <operation> <title> <typical duration> — current step for the
# progress page (title and timing only, never secrets)
progress_step() {
  mkdir -p logs
  jq -n --arg op "$1" --arg title "$2" --arg typical "$3" \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{op:$op, title:$title, typical:$typical, at:$at}' \
    > logs/current-step.json 2>/dev/null || true
}
