#!/usr/bin/env bash
# functions/preflight.sh — oc PATH fix and host prerequisite checks
# Sourced by deploy-okd.sh; not meant to be executed directly.

# ── pre-flight checks ────────────────────────────────────────────────────
fix_oc_path() {
  # On Linux hosts with k3s installed, /usr/local/bin/oc is often a symlink
  # to k3s (a kubectl shim), which shadows the real OpenShift CLI and causes
  # errors like "No help topic for 'login'". If the real oc is installed
  # under ~/.local/bin, make sure it comes first in PATH — both for this
  # run and persistently for future shells (bash and zsh).
  [ "$(uname)" = "Linux" ] || return 0
  local real_oc="$HOME/.local/bin/oc"
  [ -x "$real_oc" ] || return 0
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
  if [ "$(command -v oc 2>/dev/null)" != "$real_oc" ]; then
    log "Fixing PATH so the real oc ($real_oc) takes priority over $(command -v oc 2>/dev/null)"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [ -f "$rc" ] || continue
      grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$rc" || \
        printf '\n# added by deploy-okd.sh: keep the real oc ahead of any k3s-provided oc shim\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    done
  fi
}

preflight_checks() {
fix_oc_path

command -v docker >/dev/null || err "docker is required"
if ! docker info >/dev/null 2>&1; then
  log "Docker daemon is not running — starting it"
  if [ "$(uname)" = "Darwin" ]; then
    open -a Docker || err "could not launch Docker Desktop"
  else
    sudo systemctl start docker || err "could not start docker via systemctl"
  fi
  printf '    waiting for the daemon'
  tries=0
  until docker info >/dev/null 2>&1; do
    tries=$((tries+1))
    [ $tries -le 60 ] || { echo; err "docker daemon did not come up within 2 minutes"; }
    printf '.'; sleep 2
  done
  echo " up"
fi
command -v jq  >/dev/null    || err "jq is required (brew install jq)"
command -v oc  >/dev/null    || err "oc is required (brew install openshift-cli; then 'unset -f oc' if your zshrc shadows it)"
[ -f .env ]                  || err ".env not found (credentials/config)"
# Packer's image build needs OUTBOUND tcp/22 (Hetzner rescue sshd); on
# networks that block it the failure only surfaces ~15 min in as packer's
# "Timeout waiting for SSH". Detect it now: a build is then impossible,
# but a deploy that reuses an existing snapshot still works (ansible
# reaches the ignition host over 443).
SSH22_BLOCKED=0
if command -v nc >/dev/null && ! nc -z -w 5 github.com 22 >/dev/null 2>&1; then
  SSH22_BLOCKED=1
  log "WARNING: outbound tcp/22 is blocked on this network — the CoreOS image cannot be (re)built; only snapshot reuse will work"
fi
[ -f okd4_new_id_rsa ]       || err "okd4_new_id_rsa SSH key not found in repo root"
chmod 600 okd4_new_id_rsa
}
