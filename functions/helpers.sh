#!/usr/bin/env bash
# functions/helpers.sh — logging, progress bar, toolbox wrapper, DNS flush
# Sourced by deploy-okd.sh; not meant to be executed directly.

# ── helpers ──────────────────────────────────────────────────────────────
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# portable in-place sed (BSD sed on macOS needs -i '', GNU sed plain -i)
sedi() { if [ "$(uname)" = "Darwin" ]; then sed -i '' "$@"; else sed -i "$@"; fi; }

# progress bar + elapsed/estimate per phase
START_TS=$(date +%s)
TOTAL_STEPS=9
STEP=0
elapsed() {
  local s=$(( $(date +%s) - START_TS ))
  printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
}
step() {  # step "<title>" "<typical duration>"
  STEP=$((STEP+1))
  local width=30 filled bar
  filled=$(( STEP * width / TOTAL_STEPS ))
  bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((width-filled)) '' | tr ' ' '.')
  printf '\n\033[1;34m[%s] step %d/%d — %s\033[0m\n' "$bar" "$STEP" "$TOTAL_STEPS" "$1"
  printf '\033[0;36m    elapsed: %s | typical duration of this step: %s\033[0m\n' \
    "$(elapsed)" "$2"
}

# All make targets run inside the toolbox. --dns 1.1.1.1 bypasses Docker
# Desktop's resolver, which negative-caches our DNS records after a
# destroy/recreate cycle.
tb() {
  # the toolbox runs as root, so anything it writes into the bind-mounted
  # workspace (manifests, ignition/auth/kubeconfig, terraform state, ...)
  # would otherwise end up root-owned on the host; chown it back regardless
  # of the command's exit status
  docker run --rm --dns 1.1.1.1 --env-file .env \
    -e ANSIBLE_PRIVATE_KEY_FILE=/workspace/okd4_new_id_rsa \
    -e TF_CLI_ARGS_apply=-auto-approve \
    -v "$PWD":/workspace -w /workspace "$TOOLBOX" \
    bash -c "$*; rc=\$?; chown -R $(id -u):$(id -g) /workspace; exit \$rc"
}

flush_dns() {
  # the OS caches the records' absence from before terraform created them.
  # sudo may need a password; an unattended deploy must NOT hang on the
  # prompt (one run sat there for ~1h) — give the user 60s, then skip the
  # flush and continue. Skipping is harmless: the records are correct, the
  # local cache just takes a few extra minutes to expire.
  if ! sudo -n true 2>/dev/null && command -v timeout >/dev/null 2>&1; then
    echo
    echo "    The DNS cache flush needs your sudo password — 60s to enter it,"
    echo "    otherwise the flush is SKIPPED and the deploy continues."
    if ! timeout --foreground 60 sudo -v; then
      echo "    no password within 60s — skipping the DNS cache flush"
      return 0
    fi
  fi
  case "$(uname)" in
    Darwin)
      log "Flushing macOS DNS cache (sudo may prompt for your password)"
      sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder || true
      ;;
    Linux)
      log "Flushing Linux DNS caches (sudo may prompt for your password)"
      # systemd-resolved (Ubuntu 18.04+, Fedora, RHEL 8+ when enabled)
      if command -v resolvectl >/dev/null 2>&1; then
        sudo resolvectl flush-caches || true
      elif command -v systemd-resolve >/dev/null 2>&1; then
        sudo systemd-resolve --flush-caches || true
      fi
      # nscd (older RHEL/CentOS) and dnsmasq local caches, if present
      if systemctl is-active --quiet nscd 2>/dev/null; then
        sudo systemctl restart nscd || true
      fi
      if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        sudo systemctl restart dnsmasq || true
      fi
      ;;
  esac
}
