#!/usr/bin/env bash
#
# deploy-okd.sh — interactive OKD-on-Hetzner deployment
# Automates the full procedure from DEPLOYMENT.md, including all the
# fixes discovered on 2026-06-09/10 (DNS cache, xz images, etcd firewall,
# container-only make targets, CSR rounds).
#
set -euo pipefail
cd "$(dirname "$0")"

# ── helpers ──────────────────────────────────────────────────────────────
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# portable in-place sed (BSD sed on macOS needs -i '', GNU sed plain -i)
sedi() { if [ "$(uname)" = "Darwin" ]; then sed -i '' "$@"; else sed -i "$@"; fi; }

usage() {
  cat <<'USAGE'
Usage: ./deploy-okd.sh [options]
  --region X        Hetzner location (e.g. nbg1, fsn1, hel1, ash, hil, sin)
  --profile N       deployment profile (skips the interactive menu):
                      1 = Production - Best Servers (3 masters / 3 workers,
                          dedicated CCX types)
                      2 = Production - Cost Optimized (3 masters / 3 workers,
                          cheapest qualifying types)
                      3 = Lab (pick --lab-topology and --lab-tier)
                      4 = Manual (interactive picker, default)
  --lab-topology T  profile 3 only: 1x0, 1x1, 1x2, 1x3 or 3x3 (masters x workers)
  --lab-tier T      profile 3 only: low, mid or high (cost/spec tier)
  --masters N       master count (1/3/5; even counts need confirmation)
  --workers N       worker count
  --master-type T   server type for masters (e.g. cpx42)
  --worker-type T   server type for workers
  --duration D      lab duration: hours (8) or minutes (90m)
  --release R       OKD line (4.16) or full tag (4.16.0-okd-scos.1)
  --rebuild-image   build the CoreOS snapshot even if one exists for this release
  --no-admin        skip the htpasswd admin step
  --no-autodestroy  do not schedule the automatic teardown
  --autodestroy-at D schedule auto-destroy after D (hours or Nm minutes,
                    same syntax as --duration); defaults to --duration
  --scale           if an existing cluster is found, offer to add masters/
                    workers to it instead of refusing to proceed
  --yes             non-interactive: defaults for everything not given above
                    (profile 2: 3 masters, 3 workers, current region,
                    cheapest types, 8h)
  --help            this text
USAGE
}
FLAG_REGION="" FLAG_MASTERS="" FLAG_WORKERS="" FLAG_MASTER_TYPE="" FLAG_WORKER_TYPE=""
FLAG_DURATION="" FLAG_RELEASE="" REBUILD_IMAGE=0 NO_ADMIN=0 NO_AUTODESTROY=0 ASSUME_YES=0
FLAG_PROFILE="" FLAG_LAB_TOPOLOGY="" FLAG_LAB_TIER="" FLAG_AUTODESTROY_AT="" FLAG_SCALE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --region)         FLAG_REGION=${2:?--region needs a value}; shift 2 ;;
    --profile)        FLAG_PROFILE=${2:?--profile needs a value}; shift 2 ;;
    --lab-topology)   FLAG_LAB_TOPOLOGY=${2:?--lab-topology needs a value}; shift 2 ;;
    --lab-tier)       FLAG_LAB_TIER=${2:?--lab-tier needs a value}; shift 2 ;;
    --masters)        FLAG_MASTERS=${2:?--masters needs a value}; shift 2 ;;
    --workers)        FLAG_WORKERS=${2:?--workers needs a value}; shift 2 ;;
    --master-type)    FLAG_MASTER_TYPE=${2:?--master-type needs a value}; shift 2 ;;
    --worker-type)    FLAG_WORKER_TYPE=${2:?--worker-type needs a value}; shift 2 ;;
    --duration)       FLAG_DURATION=${2:?--duration needs a value}; shift 2 ;;
    --autodestroy-at) FLAG_AUTODESTROY_AT=${2:?--autodestroy-at needs a value}; shift 2 ;;
    --release)        FLAG_RELEASE=${2:?--release needs a value}; shift 2 ;;
    --rebuild-image)  REBUILD_IMAGE=1; shift ;;
    --no-admin)       NO_ADMIN=1; shift ;;
    --no-autodestroy) NO_AUTODESTROY=1; shift ;;
    --scale)          FLAG_SCALE=1; shift ;;
    --yes)            ASSUME_YES=1; NO_ADMIN=1; shift ;;  # passwords can't be prompted non-interactively
    --help)           usage; exit 0 ;;
    *)                usage; err "unknown option: $1" ;;
  esac
done

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
  # the OS caches the records' absence from before terraform created them
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

# ── 0. adaptive scale-up: is there already a cluster for this domain? ────
export $(grep -v '^#' .env | xargs)
DOMAIN=${TF_VAR_dns_domain:-}
if [ -n "$DOMAIN" ]; then
  EXISTING_SERVERS=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
    "https://api.hetzner.cloud/v1/servers" \
    | jq -r --arg d "$DOMAIN" '[.servers[] | select(.name | endswith("." + $d))] | length')
else
  EXISTING_SERVERS=0
fi

if [ "${EXISTING_SERVERS:-0}" -gt 0 ] 2>/dev/null; then
  CUR_MASTERS=${TF_VAR_replicas_master:-0}
  CUR_WORKERS=${TF_VAR_replicas_worker:-0}
  log "Found $EXISTING_SERVERS existing server(s) for $DOMAIN (currently $CUR_MASTERS master(s) / $CUR_WORKERS worker(s) in .env)"

  DO_SCALE=0
  if [ "$FLAG_SCALE" = 1 ]; then
    DO_SCALE=1
  elif [ "$ASSUME_YES" = 1 ]; then
    err "found $EXISTING_SERVERS server(s) of $DOMAIN in Hetzner — run ./destroy-okd.sh first, or re-run with --scale to add/remove nodes"
  else
    echo
    echo "  1) Scale — add or remove masters/workers on this cluster"
    echo "  2) Exit (run ./destroy-okd.sh first if you want a fresh deploy)"
    printf 'Selection [2]: '
    read -r SCSEL; SCSEL=${SCSEL:-2}
    [ "$SCSEL" = "1" ] && DO_SCALE=1
  fi

  if [ "$DO_SCALE" = 0 ]; then
    echo "Aborted."
    exit 0
  fi

  # ── scale flow (up and/or down) ─────────────────────────────────────
  if [ -n "$FLAG_WORKERS" ]; then NEW_WORKERS=$FLAG_WORKERS
  elif [ "$ASSUME_YES" = 1 ]; then NEW_WORKERS=$CUR_WORKERS
  else printf 'New TOTAL worker count [%d]: ' "$CUR_WORKERS"; read -r NEW_WORKERS; NEW_WORKERS=${NEW_WORKERS:-$CUR_WORKERS}; fi
  if [ -n "$FLAG_MASTERS" ]; then NEW_MASTERS=$FLAG_MASTERS
  elif [ "$ASSUME_YES" = 1 ]; then NEW_MASTERS=$CUR_MASTERS
  else printf 'New TOTAL master count [%d]: ' "$CUR_MASTERS"; read -r NEW_MASTERS; NEW_MASTERS=${NEW_MASTERS:-$CUR_MASTERS}; fi
  case "$NEW_MASTERS$NEW_WORKERS" in *[!0-9]*) err "counts must be numbers";; esac
  [ "$NEW_WORKERS" -ge 0 ] || err "worker count cannot be negative"
  [ "$NEW_MASTERS" -ge 1 ] || err "at least 1 master required"
  if [ "$NEW_MASTERS" = "$CUR_MASTERS" ] && [ "$NEW_WORKERS" = "$CUR_WORKERS" ]; then
    err "nothing to do: master/worker counts unchanged ($CUR_MASTERS/$CUR_WORKERS)"
  fi
  if [ "$NEW_MASTERS" -lt "$CUR_MASTERS" ] && [ $((NEW_MASTERS % 2)) -eq 0 ] && [ "$NEW_MASTERS" -ne 0 ]; then
    err "even master count ($NEW_MASTERS) is an etcd anti-pattern — scale to 1, 3 or 5"
  fi

  if [ "$NEW_MASTERS" -gt "$CUR_MASTERS" ]; then
    cat <<'MUPWARN'

  WARNING: adding masters to a running cluster is EXPERIMENTAL. terraform
  will create the new master VM(s) and they will join as Ready nodes via
  the usual CSR approval, but etcd membership is NOT guaranteed to be
  reconciled automatically on platform "none". After this finishes, check:
    oc get nodes
    oc get etcd -o jsonpath='{.status.conditions}'
    oc -n openshift-etcd get pods
  and consult the cluster-etcd-operator logs if the new master(s) do not
  show up as etcd members.
MUPWARN
    if [ "$ASSUME_YES" = 0 ]; then
      printf 'Continue adding masters? [y/N]: '
      read -r MOK
      [ "$MOK" = "y" ] || [ "$MOK" = "Y" ] || { echo "Aborted."; exit 0; }
    fi
  fi
  if [ "$NEW_MASTERS" -lt "$CUR_MASTERS" ]; then
    cat <<'MDOWNWARN'

  WARNING: removing masters from a running cluster is EXPERIMENTAL. This
  will drain the node, remove it from the etcd cluster via etcdctl, delete
  the Kubernetes Node object, and then have terraform destroy the VM(s)
  with the highest index(es). If the etcd member removal fails partway
  through, the cluster may be left with a stale/unhealthy etcd member —
  check `oc get etcd -o jsonpath='{.status.conditions}'` and
  `oc -n openshift-etcd get pods` afterwards.
MDOWNWARN
    if [ "$ASSUME_YES" = 0 ]; then
      printf 'Continue removing master(s)? [y/N]: '
      read -r MOK
      [ "$MOK" = "y" ] || [ "$MOK" = "Y" ] || { echo "Aborted."; exit 0; }
    fi
  fi

  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  TOOLBOX=quay.io/slauger/hcloud-okd4:$OPENSHIFT_RELEASE

  log "Toolbox image"
  if docker image inspect "$TOOLBOX" >/dev/null 2>&1; then
    echo "    $TOOLBOX already present — skipping fetch/build"
  else
    make fetch
    make build
  fi

  # ── scale-down: drain/remove nodes BEFORE terraform destroys their VMs ──
  if [ "$NEW_WORKERS" -lt "$CUR_WORKERS" ]; then
    log "Draining $((CUR_WORKERS - NEW_WORKERS)) worker node(s) before removal"
    for i in $(seq $((NEW_WORKERS + 1)) "$CUR_WORKERS"); do
      NODE=$(printf 'worker%02d.%s' "$i" "$DOMAIN")
      echo "    draining $NODE"
      oc adm cordon "$NODE" 2>/dev/null || true
      oc adm drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=180s 2>/dev/null || true
      oc delete node "$NODE" 2>/dev/null || true
    done
  fi
  if [ "$NEW_MASTERS" -lt "$CUR_MASTERS" ]; then
    log "Removing $((CUR_MASTERS - NEW_MASTERS)) master node(s) from etcd before removal"
    # any remaining etcd pod can run etcdctl against the whole cluster
    ETCD_POD=$(oc -n openshift-etcd get pods -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [ -n "$ETCD_POD" ] || echo "    WARNING: could not find an etcd pod — skipping etcdctl member removal"
    for i in $(seq $((NEW_MASTERS + 1)) "$CUR_MASTERS"); do
      NODE=$(printf 'master%02d.%s' "$i" "$DOMAIN")
      SHORT=$(printf 'master%02d' "$i")
      echo "    draining $NODE"
      oc adm cordon "$NODE" 2>/dev/null || true
      oc adm drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=180s 2>/dev/null || true
      if [ -n "$ETCD_POD" ]; then
        MEMBER_ID=$(oc -n openshift-etcd exec "$ETCD_POD" -c etcdctl -- etcdctl member list -w simple 2>/dev/null \
          | awk -F, -v n="$SHORT" '$3 ~ n {print $1}')
        if [ -n "$MEMBER_ID" ]; then
          echo "    removing etcd member $MEMBER_ID ($SHORT)"
          oc -n openshift-etcd exec "$ETCD_POD" -c etcdctl -- etcdctl member remove "$MEMBER_ID" 2>/dev/null \
            || echo "    WARNING: etcdctl member remove failed for $SHORT — check etcd health manually"
        else
          echo "    WARNING: no etcd member found matching $SHORT — skipping"
        fi
      fi
      oc delete node "$NODE" 2>/dev/null || true
    done
  fi

  sedi -E \
    -e "s|^TF_VAR_replicas_master=.*|TF_VAR_replicas_master=$NEW_MASTERS|" \
    -e "s|^TF_VAR_replicas_worker=.*|TF_VAR_replicas_worker=$NEW_WORKERS|" .env
  export $(grep -v '^#' .env | xargs)

  log "Applying infrastructure changes (terraform): $CUR_MASTERS -> $NEW_MASTERS master(s), $CUR_WORKERS -> $NEW_WORKERS worker(s)"
  tb "make infrastructure"
  flush_dns

  EXPECTED=$((NEW_MASTERS + NEW_WORKERS))
  if [ "$NEW_MASTERS" -gt "$CUR_MASTERS" ] || [ "$NEW_WORKERS" -gt "$CUR_WORKERS" ]; then
    log "Approving CSRs until all $EXPECTED nodes are Ready"
    tries=0
    while [ $tries -lt 60 ]; do
      oc get csr -o name 2>/dev/null | xargs -r oc adm certificate approve 2>/dev/null || true
      READY=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
      [ "$READY" -ge "$EXPECTED" ] && break
      tries=$((tries+1)); sleep 20
    done
  fi
  oc get nodes
  READY=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  if [ "${READY:-0}" -ge "$EXPECTED" ]; then
    echo "    all $EXPECTED nodes are Ready"
  else
    echo "    WARNING: node count is ${READY:-0}, expected $EXPECTED — check: oc get nodes / oc get csr"
  fi
  if [ "$NEW_MASTERS" -ne "$CUR_MASTERS" ]; then
    echo
    echo "    verify etcd membership:"
    echo "      oc get etcd -o jsonpath='{.status.conditions}'"
    echo "      oc -n openshift-etcd get pods"
  fi
  log "Scale complete: $NEW_MASTERS master(s), $NEW_WORKERS worker(s)"
  exit 0
fi

# ── 0b. deployment profile ────────────────────────────────────────────────
if [ -n "$FLAG_PROFILE" ]; then
  PROFILE=$FLAG_PROFILE
elif [ "$ASSUME_YES" = 1 ]; then
  PROFILE=2
elif [ -n "$FLAG_MASTERS$FLAG_WORKERS$FLAG_MASTER_TYPE$FLAG_WORKER_TYPE" ]; then
  PROFILE=4   # explicit topology/type flags given -> go straight to manual
else
  echo
  echo "Choose a deployment profile:"
  echo "  1) Production - Best Servers    (3 masters / 3 workers, dedicated CCX types)"
  echo "  2) Production - Cost Optimized  (3 masters / 3 workers, cheapest qualifying types)"
  echo "  3) Lab                          (choose topology and cost tier)"
  echo "  4) Manual                       (pick region, counts and types yourself)"
  printf 'Selection [4]: '
  read -r PROFILE; PROFILE=${PROFILE:-4}
fi
case "$PROFILE" in 1|2|3|4) ;; *) err "invalid profile: $PROFILE (must be 1-4)";; esac

# defaults a profile may override: OKD minimum specs, no type-name filter,
# "interactive" strategy = old behaviour (prompt, or cheapest with --yes)
MIN_C_MASTER=4 MIN_R_MASTER=16 MIN_C_WORKER=2 MIN_R_WORKER=8
TYPE_PREFIX="" TYPE_STRATEGY="interactive"

case "$PROFILE" in
  1)
    MASTERS=3 WORKERS=3
    MIN_C_MASTER=8 MIN_R_MASTER=32 MIN_C_WORKER=4 MIN_R_WORKER=16
    TYPE_PREFIX="ccx" TYPE_STRATEGY="cheapest"
    log "Profile 1: Production - Best Servers (3 masters / 3 workers, dedicated CCX types)"
    ;;
  2)
    MASTERS=3 WORKERS=3
    TYPE_STRATEGY="cheapest"
    log "Profile 2: Production - Cost Optimized (3 masters / 3 workers, cheapest qualifying types)"
    ;;
  3)
    if [ -n "$FLAG_LAB_TOPOLOGY" ]; then LAB_TOPOLOGY=$FLAG_LAB_TOPOLOGY
    elif [ "$ASSUME_YES" = 1 ]; then LAB_TOPOLOGY=1x1
    else
      echo
      echo "Lab topology (masters x workers):"
      echo "  1) 1x0   single node, schedulable master, no separate workers"
      echo "  2) 1x1"
      echo "  3) 1x2"
      echo "  4) 1x3"
      echo "  5) 3x3   highly available control plane"
      printf 'Selection [2]: '
      read -r TSEL; TSEL=${TSEL:-2}
      case "$TSEL" in
        1) LAB_TOPOLOGY=1x0 ;; 2) LAB_TOPOLOGY=1x1 ;; 3) LAB_TOPOLOGY=1x2 ;;
        4) LAB_TOPOLOGY=1x3 ;; 5) LAB_TOPOLOGY=3x3 ;; *) err "invalid selection";;
      esac
    fi
    case "$LAB_TOPOLOGY" in
      1x0) MASTERS=1 WORKERS=0 ;;
      1x1) MASTERS=1 WORKERS=1 ;;
      1x2) MASTERS=1 WORKERS=2 ;;
      1x3) MASTERS=1 WORKERS=3 ;;
      3x3) MASTERS=3 WORKERS=3 ;;
      *) err "invalid lab topology: $LAB_TOPOLOGY (use 1x0, 1x1, 1x2, 1x3 or 3x3)" ;;
    esac

    if [ -n "$FLAG_LAB_TIER" ]; then LAB_TIER=$FLAG_LAB_TIER
    elif [ "$ASSUME_YES" = 1 ]; then LAB_TIER=low
    else
      echo
      echo "Lab cost tier:"
      echo "  1) low   cheapest qualifying types (OKD minimum specs)"
      echo "  2) mid   mid-range types (more headroom)"
      echo "  3) high  dedicated CCX types (best performance)"
      printf 'Selection [1]: '
      read -r TIERSEL; TIERSEL=${TIERSEL:-1}
      case "$TIERSEL" in 1) LAB_TIER=low ;; 2) LAB_TIER=mid ;; 3) LAB_TIER=high ;; *) err "invalid selection";; esac
    fi
    case "$LAB_TIER" in
      low)  TYPE_STRATEGY="cheapest" ;;
      mid)  TYPE_STRATEGY="mid" ;;
      high)
        MIN_C_MASTER=8 MIN_R_MASTER=32 MIN_C_WORKER=4 MIN_R_WORKER=16
        TYPE_PREFIX="ccx" TYPE_STRATEGY="cheapest"
        ;;
      *) err "invalid lab tier: $LAB_TIER (use low, mid or high)" ;;
    esac
    log "Profile 3: Lab ($LAB_TOPOLOGY topology, $LAB_TIER cost tier)"
    ;;
  4)
    log "Profile 4: Manual"
    ;;
esac

# ── 1. region selection (live from Hetzner API) ──────────────────────────
DEFAULT_LOC=${TF_VAR_location:-nbg1}

log "Fetching Hetzner regions and live server-type availability ..."
LOCATIONS_JSON=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/locations")
DC_JSON=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/datacenters")
TYPES_JSON=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/server_types?per_page=50")
echo "$LOCATIONS_JSON" | jq -e '.locations | length > 0' >/dev/null 2>&1 \
  || err "could not fetch Hetzner locations (check HCLOUD_TOKEN)"
echo "$DC_JSON" | jq -e '.datacenters | length > 0' >/dev/null 2>&1 \
  || err "could not fetch Hetzner datacenters (check HCLOUD_TOKEN)"

# usable = x86 (the packer snapshot is x86_64) and not deprecated;
# AVAIL_BY_LOC maps location name -> [usable type ids placeable there NOW]
USABLE_IDS=$(echo "$TYPES_JSON" | jq \
  '[.server_types[] | select(.architecture=="x86" and .deprecated==false) | .id]')
AVAIL_BY_LOC=$(echo "$DC_JSON" | jq --argjson usable "$USABLE_IDS" '
  reduce .datacenters[] as $d ({};
    .[$d.location.name] = ((.[$d.location.name] // [])
      + ($d.server_types.available | map(select(. as $i | $usable | index($i))))
      | unique))')

# region rows: name city country network_zone usable_count
REGION_ROWS=$(echo "$LOCATIONS_JSON" | jq -r --argjson avail "$AVAIL_BY_LOC" '
  .locations[]
  | [.name, .city, .country, .network_zone, (($avail[.name] // []) | length)]
  | @tsv')

if [ -n "$FLAG_REGION" ] || [ "$ASSUME_YES" = 1 ]; then
  WANT=${FLAG_REGION:-$DEFAULT_LOC}
  ROW=$(echo "$REGION_ROWS" | awk -F'\t' -v l="$WANT" '$1==l')
  [ -n "$ROW" ] || err "unknown region: $WANT"
  echo "    region: $WANT"
else
  echo
  echo "Choose a region:"
  i=1 DEFAULT_IDX=1
  while IFS=$'\t' read -r name city country zone n; do
    [ "$name" = "$DEFAULT_LOC" ] && DEFAULT_IDX=$i
    if [ "$n" -eq 0 ]; then
      printf '  %d) %-5s %-20s %-13s (no usable x86 types)\n' \
        "$i" "$name" "$city, $country" "$zone"
    else
      printf '  %d) %-5s %-20s %-13s %2d x86 types available\n' \
        "$i" "$name" "$city, $country" "$zone" "$n"
    fi
    i=$((i+1))
  done <<REGIONS
$REGION_ROWS
REGIONS
  printf 'Selection [%d = %s, current .env value]: ' "$DEFAULT_IDX" "$DEFAULT_LOC"
  read -r RSEL; RSEL=${RSEL:-$DEFAULT_IDX}
  ROW=$(echo "$REGION_ROWS" | sed -n "${RSEL}p")
  [ -n "$ROW" ] || err "invalid selection"
fi
LOC=$(echo "$ROW" | cut -f1)
NETWORK_ZONE=$(echo "$ROW" | cut -f4)
[ "$(echo "$ROW" | cut -f5)" -gt 0 ] \
  || err "$LOC has no usable x86 server types right now — pick another region"

# ── 1b. live capacity & pricing check ────────────────────────────────────
log "Checking live server-type availability and pricing in $LOC ..."
AVAIL_IDS=$(echo "$AVAIL_BY_LOC" | jq --arg loc "$LOC" '.[$loc] // []')
[ "$(echo "$AVAIL_IDS" | jq 'length')" -gt 0 ] \
  || err "could not fetch live availability for $LOC (check HCLOUD_TOKEN)"

# OKD-compatible candidates: x86 (the packer snapshot is x86_64), not
# deprecated, and placeable in $LOC RIGHT NOW. Sorted by hourly price.
# Columns: name cores ram_gb disk_gb eur_per_hour(gross)
CANDIDATES=$(echo "$TYPES_JSON" | jq -r --argjson avail "$AVAIL_IDS" --arg loc "$LOC" '
  .server_types[]
  | select(.architecture=="x86" and .deprecated==false)
  | select(.id as $i | $avail | index($i))
  | . as $t
  | ($t.prices[] | select(.location==$loc) | .price_hourly.gross | tonumber) as $p
  | [$t.name, $t.cores, $t.memory, $t.disk, ($p*10000 | round / 10000)]
  | @tsv' | sort -t"$(printf '\t')" -k5 -n)
[ -n "$CANDIDATES" ] || err "no x86 server types available in $LOC right now"

pick_type() {  # pick_type <role> <min_cores> <min_ram_gb> <preset-or-empty> <name-prefix-or-empty> <strategy> → PICKED_TYPE / PICKED_PRICE
  # strategy: "interactive" (prompt, or cheapest with --yes), "cheapest", "mid"
  local role=$1 min_c=$2 min_r=$3 preset=${4:-} prefix=${5:-} strategy=${6:-interactive}
  local list flist n mid i row name cores ram disk price note sel
  list=$(echo "$CANDIDATES" | awk -F'\t' -v c="$min_c" -v r="$min_r" '$2>=c && $3>=r')
  [ -n "$list" ] || err "no $role-capable types available in $LOC right now — try another location"
  if [ -n "$prefix" ]; then
    flist=$(echo "$list" | awk -v p="^$prefix" '$0 ~ p')
    if [ -n "$flist" ]; then
      list=$flist
    else
      echo "    (no ${prefix}* type meets ${min_c} vCPU / ${min_r} GB RAM in $LOC — falling back to all qualifying types)"
    fi
  fi
  if [ -n "$preset" ]; then
    row=$(echo "$list" | awk -F'\t' -v t="$preset" '$1==t')
    [ -n "$row" ] || err "$role type '$preset' not available in $LOC (or below ${min_c} vCPU / ${min_r} GB RAM)"
    echo "    $role type: $preset"
  elif [ "$strategy" = "cheapest" ] || { [ "$strategy" = "interactive" ] && [ "$ASSUME_YES" = 1 ]; }; then
    row=$(echo "$list" | head -1)
    echo "    $role type: $(echo "$row" | cut -f1) (cheapest qualifying)"
  elif [ "$strategy" = "mid" ]; then
    n=$(echo "$list" | wc -l | tr -d ' ')
    mid=$(( (n + 1) / 2 ))
    row=$(echo "$list" | sed -n "${mid}p")
    echo "    $role type: $(echo "$row" | cut -f1) (mid-range, $mid of $n qualifying types)"
  else
    echo
    echo "Available $role types in $LOC (OKD minimum: ${min_c} vCPU / ${min_r} GB RAM; >=100 GB disk recommended):"
    i=1
    while IFS=$'\t' read -r name cores ram disk price; do
      note=""
      [ "$disk" -lt 100 ] && note="  (disk <100 GB)"
      printf '  %d) %-7s %2d vCPU  %3d GB RAM  %4d GB disk  %.4f EUR/h%s\n' \
        "$i" "$name" "$cores" "$ram" "$disk" "$price" "$note"
      i=$((i+1))
    done <<LIST
$list
LIST
    printf 'Choose %s type [1 = cheapest]: ' "$role"
    read -r sel; sel=${sel:-1}
    row=$(echo "$list" | sed -n "${sel}p")
    [ -n "$row" ] || err "invalid selection"
  fi
  PICKED_TYPE=$(echo "$row" | cut -f1)
  PICKED_PRICE=$(echo "$row" | cut -f5)
}

# ── 2. topology & instance types ─────────────────────────────────────────
# profiles 1-3 already set MASTERS/WORKERS; profile 4 (manual) prompts here
if [ "$PROFILE" = 4 ]; then
  if [ -n "$FLAG_MASTERS" ]; then MASTERS=$FLAG_MASTERS
  elif [ "$ASSUME_YES" = 1 ]; then MASTERS=3
  else printf '\nHow many MASTER nodes? [1]: '; read -r MASTERS; MASTERS=${MASTERS:-1}; fi
  if [ -n "$FLAG_WORKERS" ]; then WORKERS=$FLAG_WORKERS
  elif [ "$ASSUME_YES" = 1 ]; then WORKERS=3
  else printf 'How many WORKER nodes? [1]: '; read -r WORKERS; WORKERS=${WORKERS:-1}; fi
fi
case "$MASTERS$WORKERS" in *[!0-9]*) err "counts must be numbers";; esac
[ "$MASTERS" -ge 1 ] || err "at least 1 master required"

# etcd quorum: an even member count tolerates no more failures than the
# next-lower odd one, and 2 masters tolerate NONE (worse than 1)
if [ $((MASTERS % 2)) -eq 0 ]; then
  cat <<'QUORUM'

  WARNING: even master counts are an etcd anti-pattern. etcd needs a strict
  majority (quorum) for every write: with 2 masters, quorum is 2, so losing
  EITHER node freezes the whole control plane — more cost than 1 master,
  less reliability. 4 tolerates no more failures than 3. Use 1, 3 or 5.
QUORUM
  [ "$ASSUME_YES" = 1 ] && err "even master count ($MASTERS) rejected in --yes mode — use 1, 3 or 5"
  printf 'Continue anyway? [y/N]: '
  read -r QOK
  [ "$QOK" = "y" ] || [ "$QOK" = "Y" ] || { echo "Aborted."; exit 0; }
fi

pick_type "master" "$MIN_C_MASTER" "$MIN_R_MASTER" "$FLAG_MASTER_TYPE" "$TYPE_PREFIX" "$TYPE_STRATEGY"
MASTER_TYPE=$PICKED_TYPE MASTER_PRICE=$PICKED_PRICE
pick_type "worker" "$MIN_C_WORKER" "$MIN_R_WORKER" "$FLAG_WORKER_TYPE" "$TYPE_PREFIX" "$TYPE_STRATEGY"
WORKER_TYPE=$PICKED_TYPE WORKER_PRICE=$PICKED_PRICE

# bootstrap mirrors the master choice (temporary, deleted after bootstrap);
# ignition gets the cheapest available type (it only serves one file)
BOOTSTRAP_TYPE=$MASTER_TYPE BOOTSTRAP_PRICE=$MASTER_PRICE
IGNITION_TYPE=$(echo "$CANDIDATES" | head -1 | cut -f1)
IGNITION_PRICE=$(echo "$CANDIDATES" | head -1 | cut -f5)

# packer build server (temporary, only writes the CoreOS image in rescue
# mode): keep cx33 if this region has it, else cheapest with >=4 GB RAM
if echo "$CANDIDATES" | cut -f1 | grep -qx "cx33"; then
  PACKER_TYPE=cx33
else
  PACKER_TYPE=$(echo "$CANDIDATES" | awk -F'\t' '$3>=4' | head -1 | cut -f1)
fi
[ -n "$PACKER_TYPE" ] || err "no packer-capable type (>=4 GB RAM) available in $LOC"
echo
echo "  bootstrap : $BOOTSTRAP_TYPE (same as master, temporary)"
echo "  ignition  : $IGNITION_TYPE (cheapest available, temporary)"
echo "  packer    : $PACKER_TYPE (image build, temporary)"

# ── 3. cost estimate ─────────────────────────────────────────────────────
if [ -n "$FLAG_DURATION" ]; then DUR=$FLAG_DURATION
elif [ "$ASSUME_YES" = 1 ]; then DUR=8
else
  printf '\nHow long will the lab run? Hours (e.g. 8) or minutes with m suffix (e.g. 90m) [8]: '
  read -r DUR; DUR=${DUR:-8}
fi
case "$DUR" in
  *m) HOURS=$(awk -v m="${DUR%m}" 'BEGIN{printf "%.2f", m/60}') ;;
  *)  HOURS=$DUR ;;
esac
awk -v h="$HOURS" 'BEGIN{exit !(h+0>0)}' || err "invalid duration: $DUR"

awk -v m="$MASTERS" -v w="$WORKERS" -v pm="$MASTER_PRICE" -v pw="$WORKER_PRICE" \
    -v pb="$BOOTSTRAP_PRICE" -v pi="$IGNITION_PRICE" -v h="$HOURS" \
    -v mt="$MASTER_TYPE" -v wt="$WORKER_TYPE" 'BEGIN{
  cluster = m*pm + w*pw
  temp    = pb + pi
  printf "\n  Cost estimate (gross prices, Hetzner bills per started hour):\n"
  printf "    %d x master %-7s : %.4f EUR/h\n", m, mt, m*pm
  printf "    %d x worker %-7s : %.4f EUR/h\n", w, wt, w*pw
  printf "    cluster hourly rate  : %.4f EUR/h\n", cluster
  printf "    bootstrap + ignition : %.4f EUR one-off (live ~1h during install)\n", temp
  printf "    ───────────────────────────────────────\n"
  printf "    estimated for %.2f h : %.2f EUR\n", h, cluster*h + temp
  printf "    (excludes load balancer, primary IPs, snapshot storage and traffic)\n"
}'
if [ "$ASSUME_YES" = 1 ]; then
  echo; echo "Proceeding (--yes)."
else
  printf '\nProceed with the deployment? [y/N]: '
  read -r GO
  [ "$GO" = "y" ] || [ "$GO" = "Y" ] || { echo "Aborted."; exit 0; }
fi

# ── 4. version (menu, or --release) ──────────────────────────────────────
if [ -n "$FLAG_RELEASE" ] && ! echo "$FLAG_RELEASE" | grep -Eq '^[0-9]+\.[0-9]+$'; then
  # full tag given verbatim, e.g. 4.16.0-okd-scos.1
  OPENSHIFT_RELEASE=$FLAG_RELEASE
  log "Using OKD release $OPENSHIFT_RELEASE (from --release)"
else
  if [ -n "$FLAG_RELEASE" ]; then
    PREFIX=$FLAG_RELEASE
  elif [ "$ASSUME_YES" = 1 ]; then
    PREFIX=4.16
  else
    log "Choose an OKD version:"
    LINES="4.14 4.16 4.18 4.20 4.22 5.0"
    i=1
    for v in $LINES; do echo "  $i) $v"; i=$((i+1)); done
    printf 'Selection [matching 4.16]: '
    read -r SEL; SEL=${SEL:-2}
    PREFIX=$(echo $LINES | awk -v n="$SEL" '{print $n}')
    [ -n "$PREFIX" ] || err "invalid selection"
  fi

  log "Resolving latest release tag for OKD $PREFIX ..."
  RELDIR=$(mktemp -d); trap 'rm -rf "$RELDIR"' EXIT
  for p in 1 2 3 4 5 6; do
    curl -s "https://api.github.com/repos/okd-project/okd/releases?per_page=100&page=$p" \
      -o "$RELDIR/rel_$p.json"
    jq -e 'type=="array"' "$RELDIR/rel_$p.json" >/dev/null \
      || err "GitHub API error: $(jq -r '.message // "invalid response"' "$RELDIR/rel_$p.json")"
  done
  ALL_RELEASES=$(jq -s 'add' "$RELDIR"/rel_*.json)
  OPENSHIFT_RELEASE=$(echo "$ALL_RELEASES" | jq -r --arg p "$PREFIX" '
    [ .[] | select(.tag_name | startswith($p)) ] as $m
    | ([ $m[] | select(.prerelease == false) ]
       | if length > 0 then .[0].tag_name else ($m[0].tag_name // empty) end)')
  [ -n "$OPENSHIFT_RELEASE" ] && [ "$OPENSHIFT_RELEASE" != "null" ] \
    || err "no release found for $PREFIX"
  PRE=$(echo "$ALL_RELEASES" | jq -r --arg t "$OPENSHIFT_RELEASE" \
    '.[] | select(.tag_name==$t) | .prerelease')
  echo "    -> $OPENSHIFT_RELEASE $([ "$PRE" = "true" ] && echo '(PRERELEASE — no stable exists for this line)')"
fi

# ── 5. write the choices into .env / install-config.yaml ────────────────
step "Updating .env and install-config.yaml" "instant"
sedi -E \
  -e "s|^OPENSHIFT_RELEASE=.*|OPENSHIFT_RELEASE=$OPENSHIFT_RELEASE|" \
  -e "s|^TF_VAR_replicas_master=.*|TF_VAR_replicas_master=$MASTERS|" \
  -e "s|^TF_VAR_replicas_worker=.*|TF_VAR_replicas_worker=$WORKERS|" \
  -e "s|^TF_VAR_server_type_master=.*|TF_VAR_server_type_master=$MASTER_TYPE|" \
  -e "s|^TF_VAR_server_type_worker=.*|TF_VAR_server_type_worker=$WORKER_TYPE|" \
  -e "s|^TF_VAR_server_type_bootstrap=.*|TF_VAR_server_type_bootstrap=$BOOTSTRAP_TYPE|" \
  -e "s|^TF_VAR_server_type_ignition=.*|TF_VAR_server_type_ignition=$IGNITION_TYPE|" \
  -e "s|^TF_VAR_location=.*|TF_VAR_location=$LOC|" \
  -e "s|^TF_VAR_network_zone=.*|TF_VAR_network_zone=$NETWORK_ZONE|" \
  -e "s|^PACKER_LOCATION=.*|PACKER_LOCATION=$LOC|" \
  -e "s|^PACKER_SERVER_TYPE=.*|PACKER_SERVER_TYPE=$PACKER_TYPE|" .env
# older .env files predate this line; sed substitution is a no-op then
grep -q '^TF_VAR_network_zone=' .env \
  || echo "TF_VAR_network_zone=$NETWORK_ZONE" >> .env

# controlPlane.replicas = masters; compute.replicas stays 0 (terraform
# creates the worker VMs; they join via CSR approval)
python3 - "$MASTERS" <<'EOF'
import sys, yaml
m = int(sys.argv[1])
d = yaml.safe_load(open('install-config.yaml'))
d['controlPlane']['replicas'] = m
d['compute'][0]['replicas'] = 0
yaml.safe_dump(d, open('install-config.yaml', 'w'), default_flow_style=False)
EOF

export $(grep -v '^#' .env | xargs)
TOOLBOX=quay.io/slauger/hcloud-okd4:$OPENSHIFT_RELEASE
DOMAIN=$TF_VAR_dns_domain

# (existing-cluster / scale-up check already happened in step 0, above)

# ── 6. toolbox image (fetch/build are the ONLY host-side make targets) ──
step "Toolbox image" "skipped if cached, else 5-10 min download+build"
if docker image inspect "$TOOLBOX" >/dev/null 2>&1; then
  echo "    $TOOLBOX already present — skipping fetch/build"
else
  log "Fetching installer tarballs (~700 MB) and building toolbox image"
  make fetch
  make build
fi

# ── 7. fresh install configs (certs are valid only 24h) ─────────────────
if [ -d ignition/auth ] && [ -n "$(ls -A ignition/auth 2>/dev/null)" ]; then
  BAK="ignition-auth-backup-$(date +%Y%m%d-%H%M%S)"
  log "Backing up previous cluster credentials to $BAK/"
  cp -r ignition/auth "$BAK"
fi
# Cleanup runs INSIDE the container as well: with Docker Desktop's virtiofs
# mounts the container can briefly see a stale view of a dir removed on the
# host — mkdir then fails with "File exists", and busybox rm can fail with
# "can't remove ... No such file or directory" (stat says it exists, the
# removal then hits ENOENT). A single rm exit code is therefore meaningless
# here; what matters is the postcondition "the container sees them gone".
rm -rf config ignition
step "Generating manifests and ignition configs" "~1 min"
tb 'for i in 1 2 3 4 5; do
      rm -rf config ignition 2>/dev/null
      [ ! -e config ] && [ ! -e ignition ] && exit 0
      sleep 2
    done
    echo "ERROR: stale config/ignition still visible in the container after retries" >&2
    exit 1'
tb "make generate_manifests && make generate_ignition"

# ── 8. CoreOS snapshot (reused when one exists for this release) ─────────
step "CoreOS image" "skipped if a snapshot for this release exists, else 2-5 min"
FCOS_RELEASE=$(tb "openshift-install coreos print-stream-json \
  | jq -r '.architectures.x86_64.artifacts.qemu.release'" | tr -d '[:space:]')
[ -n "$FCOS_RELEASE" ] || err "could not determine the CoreOS release from the toolbox"
sedi -E -e "s|^TF_VAR_fcos_release=.*|TF_VAR_fcos_release=$FCOS_RELEASE|" .env
grep -q '^TF_VAR_fcos_release=' .env \
  || echo "TF_VAR_fcos_release=$FCOS_RELEASE" >> .env
# an API hiccup must never skip a NEEDED build — fall back to building
SNAP_COUNT=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/images?type=snapshot&status=available&label_selector=os=fcos,fcos_release=$FCOS_RELEASE" \
  | jq -r '.images | length' 2>/dev/null) || SNAP_COUNT=0
if [ "${SNAP_COUNT:-0}" -gt 0 ] 2>/dev/null && [ "$REBUILD_IMAGE" = 0 ]; then
  echo "    snapshot for CoreOS $FCOS_RELEASE already exists — skipping build (--rebuild-image to force)"
else
  [ "$SSH22_BLOCKED" = 0 ] \
    || err "a CoreOS image build is needed (no snapshot for $FCOS_RELEASE) but outbound tcp/22 is blocked here — build once from a network that allows SSH, or pick a release whose snapshot exists"
  tb "make hcloud_image"
fi

# ── 9. infrastructure + bootstrap ────────────────────────────────────────
step "Deploying infrastructure (terraform + ansible, BOOTSTRAP=true)" "3-5 min"
tb "make infrastructure BOOTSTRAP=true"
flush_dns   # records were just (re)created — drop any negative cache

# ── 9b. bootstrap ignition-race watchdog ─────────────────────────────────
# The bootstrap VM boots while ansible is still uploading bootstrap.ign to
# the ignition host. If Apache answers 404 in that window, Ignition treats
# the 4xx as permanent, drops to the emergency shell and the node stays
# dark forever (masters are safe: they get connection-refused from the
# not-yet-running MCS, which Ignition retries). If the bootstrap MCS is
# still down minutes after the upload, hard-reset the node once — a fresh
# boot finds the file.
step "Waiting for the bootstrap machine-config server" "2-6 min"
B_JSON=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/servers?name=bootstrap01.$DOMAIN")
B_ID=$(echo "$B_JSON" | jq -r '.servers[0].id // empty')
B_IP=$(echo "$B_JSON" | jq -r '.servers[0].public_net.ipv4.ip // empty')
if [ -n "$B_IP" ] && [ -n "$B_ID" ]; then
  RESET_DONE=0 t=0
  until curl -ksf --max-time 5 "https://$B_IP:22623/healthz" >/dev/null 2>&1; do
    t=$((t+1))
    if [ "$t" -ge 18 ] && [ "$RESET_DONE" = 0 ]; then
      log "MCS still dark after ~6 min — bootstrap likely lost the ignition race; hard-resetting it"
      curl -s -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
        "https://api.hetzner.cloud/v1/servers/$B_ID/actions/reset" >/dev/null
      RESET_DONE=1
    fi
    if [ "$t" -gt 45 ]; then
      log "MCS still down after ~15 min — continuing; the bootstrap watcher will report"
      break
    fi
    sleep 20
  done
else
  echo "    could not determine the bootstrap server — skipping the race check"
fi

step "Waiting for bootstrap to complete" "15-40 min (longest phase)"
echo "    Watcher is read-only; if it times out the install continues — retried once."
tb "make wait_bootstrap" || { log "Watcher timed out — retrying once"; tb "make wait_bootstrap"; }

# ── 10. remove bootstrap, wait for completion ─────────────────────────────
step "Removing bootstrap + ignition nodes" "1-2 min"
tb "make infrastructure"

# ── install watchdog (runs during the install-complete wait) ─────────────
# On platform "none" nothing in the cluster approves node CSRs, so approve
# them as they appear. 4.16 apiserver rollouts can additionally deadlock:
# the new oauth/openshift-apiserver replica sits Pending on pod
# anti-affinity because an old-generation pod never frees its master slot.
# Evict one old pod to unstick the rollout, and force-clean pods stuck
# Terminating so they cannot hold the slot either.
install_watchdog() {
  while :; do
    oc get csr -o name 2>/dev/null | xargs -r oc adm certificate approve >/dev/null 2>&1 || true
    for ns in openshift-oauth-apiserver openshift-apiserver; do
      NOW=$(date +%s)
      VICTIM=$(oc -n "$ns" get pods -o json 2>/dev/null | jq -r --argjson now "$NOW" '
        .items as $all
        | [ $all[]
            | select(.status.phase=="Pending")
            | select([.status.conditions[]?
                      | select(.type=="PodScheduled" and .reason=="Unschedulable")
                      | .message // ""] | join(" ") | test("anti-affinity"))
            | select(($now - (.metadata.creationTimestamp | fromdateiso8601)) > 180)
          ][0] as $p
        | if $p == null then empty
          else [ $all[]
                 | select(.metadata.deletionTimestamp == null)
                 | select(.status.phase == "Running")
                 | select(.metadata.labels["pod-template-hash"] != $p.metadata.labels["pod-template-hash"])
                 | .metadata.name ][0] // empty
          end' 2>/dev/null)
      if [ -n "$VICTIM" ]; then
        log "Watchdog: rollout in $ns deadlocked on anti-affinity — evicting old pod $VICTIM"
        oc -n "$ns" delete pod "$VICTIM" --wait=false >/dev/null 2>&1 || true
      fi
      oc -n "$ns" get pods -o json 2>/dev/null | jq -r --argjson now "$NOW" '
        .items[]
        | select(.metadata.deletionTimestamp != null)
        | select(($now - (.metadata.deletionTimestamp | fromdateiso8601)) > 300)
        | .metadata.name' 2>/dev/null \
      | xargs -r -I{} oc -n "$ns" delete pod {} --force --grace-period=0 >/dev/null 2>&1 || true
      # a pod scheduled to a node but still Pending >10 min is wedged on that
      # node (hung image pull was seen to block a rollout for ~50 min) —
      # delete it so the controller reschedules and the pull restarts
      STUCK=$(oc -n "$ns" get pods -o json 2>/dev/null | jq -r --argjson now "$NOW" '
        .items[]
        | select(.metadata.deletionTimestamp == null)
        | select(.status.phase == "Pending")
        | select((.spec.nodeName // "") != "")
        | select(($now - (.metadata.creationTimestamp | fromdateiso8601)) > 600)
        | .metadata.name' 2>/dev/null)
      for p in $STUCK; do
        log "Watchdog: pod $ns/$p stuck Pending on its node >10 min — deleting to retrigger"
        oc -n "$ns" delete pod "$p" --wait=false >/dev/null 2>&1 || true
      done
    done
    sleep 30
  done
}
export KUBECONFIG=$PWD/ignition/auth/kubeconfig
install_watchdog &
WATCHDOG=$!
trap '[ -n "${WATCHDOG:-}" ] && kill "$WATCHDOG" 2>/dev/null; [ -n "${RELDIR:-}" ] && rm -rf "$RELDIR"; :' EXIT

step "Waiting for install completion" "5-25 min"
tb "make wait_completion" || { log "Watcher timed out — retrying once"; tb "make wait_completion"; }
kill "$WATCHDOG" 2>/dev/null || true

# ── 11. join the workers (CSR rounds until everyone is Ready) ─────────────
export KUBECONFIG=$PWD/ignition/auth/kubeconfig
EXPECTED=$((MASTERS + WORKERS))
step "Approving CSRs until all $EXPECTED nodes are Ready" "2-10 min"
tries=0
while [ $tries -lt 60 ]; do
  oc get csr -o name 2>/dev/null | xargs -r oc adm certificate approve 2>/dev/null || true
  READY=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  [ "$READY" -ge "$EXPECTED" ] && break
  tries=$((tries+1)); sleep 20
done
oc get nodes
[ "${READY:-0}" -ge "$EXPECTED" ] || err "not all nodes became Ready — approve remaining CSRs manually: oc get csr"

# ── 11b. schedule the teardown ───────────────────────────────────────────
AD_DUR=${FLAG_AUTODESTROY_AT:-$DUR}
case "$AD_DUR" in
  *m) AD_HOURS=$(awk -v m="${AD_DUR%m}" 'BEGIN{printf "%.4f", m/60}') ;;
  *)  AD_HOURS=$AD_DUR ;;
esac
awk -v h="$AD_HOURS" 'BEGIN{exit !(h+0>0)}' || err "invalid --autodestroy-at: $FLAG_AUTODESTROY_AT"
DEADLINE_TS=$(( $(date +%s) + $(awk -v h="$AD_HOURS" 'BEGIN{printf "%d", h*3600}') ))
if [ "$(uname)" = "Darwin" ]; then
  DEADLINE_HUMAN=$(date -r "$DEADLINE_TS" '+%Y-%m-%d %H:%M')
else
  DEADLINE_HUMAN=$(date -d "@$DEADLINE_TS" '+%Y-%m-%d %H:%M')
fi
AUTODESTROY_NOTE="teardown deadline: $DEADLINE_HUMAN — NOT scheduled, run ./destroy-okd.sh yourself"
if [ "$(uname)" = "Darwin" ] && [ "$NO_AUTODESTROY" = 0 ]; then
  if [ "$ASSUME_YES" = 1 ]; then SCHED=y
  else
    printf '\nSchedule auto-destroy at %s? [Y/n]: ' "$DEADLINE_HUMAN"
    read -r SCHED; SCHED=${SCHED:-y}
  fi
  if [ "$SCHED" = "y" ] || [ "$SCHED" = "Y" ]; then
    LABEL=com.hcloud-okd4.autodestroy
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    UID_N=$(id -u)
    launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
    mkdir -p "$HOME/Library/LaunchAgents"
    D_MON=$((10#$(date -r "$DEADLINE_TS" +%m)))
    D_DAY=$((10#$(date -r "$DEADLINE_TS" +%d)))
    D_HR=$((10#$(date -r "$DEADLINE_TS" +%H)))
    D_MIN=$((10#$(date -r "$DEADLINE_TS" +%M)))
    # the job boots itself out LAST (bootout SIGTERMs the job's own shell);
    # destroy-okd.sh skips its cancel logic when HCLOUD_OKD4_SCHEDULED=1
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>EnvironmentVariables</key><dict>
    <key>HCLOUD_OKD4_SCHEDULED</key><string>1</string>
  </dict>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>-c</string>
    <string>cd $PWD &amp;&amp; ./destroy-okd.sh --yes &gt;&gt; autodestroy.log 2&gt;&amp;1; rm -f $PLIST; launchctl bootout gui/$UID_N/$LABEL</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Month</key><integer>$D_MON</integer>
    <key>Day</key><integer>$D_DAY</integer>
    <key>Hour</key><integer>$D_HR</integer>
    <key>Minute</key><integer>$D_MIN</integer>
  </dict>
</dict></plist>
PLISTEOF
    if launchctl bootstrap "gui/$UID_N" "$PLIST" 2>/dev/null; then
      AUTODESTROY_NOTE="auto-destroy : scheduled for $DEADLINE_HUMAN (fires on next wake if the Mac slept past it)
  cancel with : launchctl bootout gui/$UID_N/$LABEL   (a manual ./destroy-okd.sh also cancels it)"
    else
      rm -f "$PLIST"
      AUTODESTROY_NOTE="auto-destroy : scheduling FAILED — run ./destroy-okd.sh manually by $DEADLINE_HUMAN"
    fi
  fi
elif [ "$(uname)" = "Linux" ] && [ "$NO_AUTODESTROY" = 0 ]; then
  if [ "$ASSUME_YES" = 1 ]; then SCHED=y
  else
    printf '\nSchedule auto-destroy at %s? [Y/n]: ' "$DEADLINE_HUMAN"
    read -r SCHED; SCHED=${SCHED:-y}
  fi
  if [ "$SCHED" = "y" ] || [ "$SCHED" = "Y" ]; then
    UNIT=hcloud-okd4-autodestroy
    AD_SECONDS=$(( DEADLINE_TS - $(date +%s) ))
    [ "$AD_SECONDS" -gt 0 ] || AD_SECONDS=60
    # cancel any previous timer for this checkout first
    systemctl --user stop "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1 || true
    rm -f .autodestroy-atjob
    if command -v systemd-run >/dev/null 2>&1 && systemd-run --user \
        --unit="$UNIT" \
        --on-active="${AD_SECONDS}s" \
        bash -c "cd $PWD && HCLOUD_OKD4_SCHEDULED=1 ./destroy-okd.sh --yes >> autodestroy.log 2>&1" >/dev/null 2>&1; then
      AUTODESTROY_NOTE="auto-destroy : scheduled for $DEADLINE_HUMAN via systemd --user timer ($UNIT.timer)
  cancel with : systemctl --user stop $UNIT.timer $UNIT.service   (a manual ./destroy-okd.sh also cancels it)
  NOTE: --user timers only fire while you are logged in, unless lingering is
  enabled (sudo loginctl enable-linger \$USER)."
    elif command -v at >/dev/null 2>&1 && AT_OUT=$(printf 'cd %s && HCLOUD_OKD4_SCHEDULED=1 ./destroy-okd.sh --yes >> autodestroy.log 2>&1\n' "$PWD" \
        | at -M "now + $(( (AD_SECONDS + 59) / 60 )) minutes" 2>&1); then
      AT_JOB=$(echo "$AT_OUT" | grep -oE 'job [0-9]+' | awk '{print $2}')
      [ -n "$AT_JOB" ] && echo "$AT_JOB" > .autodestroy-atjob
      AUTODESTROY_NOTE="auto-destroy : scheduled for $DEADLINE_HUMAN via 'at' (job ${AT_JOB:-?})
  cancel with : atrm ${AT_JOB:-<job-id>}   (a manual ./destroy-okd.sh also cancels it)"
    else
      AUTODESTROY_NOTE="auto-destroy : scheduling FAILED (no systemd --user or at available) — run ./destroy-okd.sh manually by $DEADLINE_HUMAN"
    fi
  fi
fi

# ── 11c. htpasswd admin user ─────────────────────────────────────────────
ADMIN_CREATED=""
create_admin() {
  command -v htpasswd >/dev/null \
    || { echo "    htpasswd binary not found — manual steps are in the summary"; return 1; }
  local user pass pass2 attempt=0 tmp t lkc
  printf 'Admin username [admin]: '
  read -r user; user=${user:-admin}
  while :; do
    attempt=$((attempt+1))
    printf 'Password for %s: ' "$user"; read -rs pass; echo
    printf 'Repeat password : '; read -rs pass2; echo
    [ -n "$pass" ] && [ "$pass" = "$pass2" ] && break
    [ $attempt -ge 3 ] && { echo "    giving up — manual steps are in the summary"; return 1; }
    echo "    empty or mismatched — try again"
  done
  tmp=$(mktemp -d)   # mktemp -d is 0700
  htpasswd -c -B -b "$tmp/users.htpasswd" "$user" "$pass" >/dev/null 2>&1
  oc create secret generic htpass-secret \
    --from-file=htpasswd="$tmp/users.htpasswd" -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -
  rm -rf "$tmp"
  oc apply -f - <<'OAUTH'
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd_provider
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
OAUTH
  oc adm policy add-cluster-role-to-user cluster-admin "$user"
  echo "    waiting for the OAuth server to accept the new login (2-5 min typical)"
  t=0; lkc=$(mktemp)
  until KUBECONFIG=$lkc oc login --server="https://api.$DOMAIN:6443" \
        --insecure-skip-tls-verify=true -u "$user" -p "$pass" >/dev/null 2>&1; do
    t=$((t+1))
    [ $t -le 30 ] || { rm -f "$lkc"; echo "    login still failing after 10 min — check: oc get co authentication"; return 1; }
    sleep 20
  done
  rm -f "$lkc"
  echo "    verified: $user can log in"
  ADMIN_CREATED=$user
  printf 'Delete kubeadmin (recommended once the new admin works)? [y/N]: '
  read -r DELKA
  if [ "$DELKA" = "y" ] || [ "$DELKA" = "Y" ]; then
    oc delete secret kubeadmin -n kube-system && echo "    kubeadmin removed"
  fi
  return 0
}
if [ "$NO_ADMIN" = 0 ]; then
  printf '\nCreate htpasswd admin user (replaces kubeadmin)? [Y/n]: '
  read -r MKADMIN; MKADMIN=${MKADMIN:-y}
  if [ "$MKADMIN" = "y" ] || [ "$MKADMIN" = "Y" ]; then
    create_admin || true
  fi
fi

# ── 12. summary ──────────────────────────────────────────────────────────
KUBEADMIN_PW=$(cat ignition/auth/kubeadmin-password)
if [ -n "$ADMIN_CREATED" ]; then
  CRED_USER=$ADMIN_CREATED
  CRED_PASS="(the password you typed)"
else
  CRED_USER=kubeadmin
  CRED_PASS=$KUBEADMIN_PW
fi
cat <<SUMMARY

═══════════════════════════════════════════════════════════════════
  OKD $OPENSHIFT_RELEASE deployed: $MASTERS master(s), $WORKERS worker(s)
  Total time: $(elapsed)
═══════════════════════════════════════════════════════════════════

  Web console : https://console-openshift-console.apps.$DOMAIN
  Username    : $CRED_USER
  Password    : $CRED_PASS

  CLI         : export KUBECONFIG=\$PWD/ignition/auth/kubeconfig
  SSH         : ssh -i okd4_new_id_rsa core@<node-ip>

  $AUTODESTROY_NOTE
SUMMARY
if [ -z "$ADMIN_CREATED" ]; then
cat <<'HOWTO'
───────────────────────────────────────────────────────────────────
  "You are logged in as a temporary administrative user."
  To replace kubeadmin with a real htpasswd user:

    htpasswd -c -B -b users.htpasswd admin 'YOUR_PASSWORD'
    oc create secret generic htpass-secret \
       --from-file=htpasswd=users.htpasswd -n openshift-config
    oc apply -f - <<'EOF'
    apiVersion: config.openshift.io/v1
    kind: OAuth
    metadata:
      name: cluster
    spec:
      identityProviders:
      - name: htpasswd_provider
        mappingMethod: claim
        type: HTPasswd
        htpasswd:
          fileData:
            name: htpass-secret
    EOF
    oc adm policy add-cluster-role-to-user cluster-admin admin

  After verifying the new admin works, remove kubeadmin:
    oc delete secret kubeadmin -n kube-system
───────────────────────────────────────────────────────────────────
HOWTO
fi
