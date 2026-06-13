#!/usr/bin/env bash
# functions/cluster-scale.sh — scale an existing cluster up/down (or jump to monitoring)
# Sourced by deploy-okd.sh; not meant to be executed directly.

# Called when servers for TF_VAR_dns_domain already exist; always exits.
handle_existing_cluster() {
  CUR_MASTERS=${TF_VAR_replicas_master:-0}
  CUR_WORKERS=${TF_VAR_replicas_worker:-0}
  log "Found $EXISTING_SERVERS existing server(s) for $DOMAIN (currently $CUR_MASTERS master(s) / $CUR_WORKERS worker(s) in .env)"

  DO_SCALE=0
  if [ "$FLAG_SCALE" = 1 ]; then
    DO_SCALE=1
  elif [ "$FLAG_MONITORING" = 1 ]; then
    # configure monitoring on the already-running cluster, nothing else
    install_monitoring || exit 1
    log "Done: $MONITORING_NOTE"
    exit 0
  elif [ "$FLAG_ADMIN" = 1 ]; then
    [ "$ASSUME_YES" = 0 ] || err "--admin needs an interactive terminal (the password is prompted)"
    create_admin || exit 1
    log "Done: admin user '$ADMIN_CREATED' created"
    exit 0
  elif [ "$ASSUME_YES" = 1 ]; then
    err "found $EXISTING_SERVERS server(s) of $DOMAIN in Hetzner — run ./destroy-okd.sh first, or re-run with --scale / --monitoring"
  else
    echo
    echo "  1) Scale — add or remove masters/workers on this cluster"
    MON_MAX_GB=$(KUBECONFIG=$PWD/ignition/auth/kubeconfig max_node_ram_gb 2>/dev/null || echo 0)
    if awk -v g="${MON_MAX_GB:-0}" 'BEGIN{exit !(g+0>12)}'; then
      echo "  2) Monitoring — configure monitoring, alerting & Grafana (largest node: ${MON_MAX_GB} GB RAM)"
    else
      echo "  2) Monitoring — UNAVAILABLE (needs a node with >12 GB RAM, largest is ${MON_MAX_GB:-0} GB)"
    fi
    echo "  3) Admin — create htpasswd admin user (replaces kubeadmin)"
    echo "  4) Exit (run ./destroy-okd.sh first if you want a fresh deploy)"
    printf 'Selection [4]: '
    read -r SCSEL; SCSEL=${SCSEL:-4}
    case "$SCSEL" in
      1) DO_SCALE=1 ;;
      2) install_monitoring || exit 1
         log "Done: $MONITORING_NOTE"
         exit 0 ;;
      3) create_admin || exit 1
         log "Done: admin user '$ADMIN_CREATED' created"
         exit 0 ;;
    esac
  fi

  if [ "$DO_SCALE" = 0 ]; then
    echo "Aborted."
    exit 0
  fi

  # ── scale flow (up and/or down) ─────────────────────────────────────
  # If the user passed --workers and/or --masters, take those verbatim and
  # KEEP the other dimension unchanged WITHOUT prompting — `--scale
  # --workers 4` must mean "workers->4, masters untouched", never ask about
  # masters. Only prompt for a value when NEITHER flag was given (fully
  # interactive scale).
  if [ -n "$FLAG_WORKERS" ] || [ -n "$FLAG_MASTERS" ]; then
    NEW_WORKERS=${FLAG_WORKERS:-$CUR_WORKERS}
    NEW_MASTERS=${FLAG_MASTERS:-$CUR_MASTERS}
    echo "    workers: $CUR_WORKERS -> $NEW_WORKERS$([ -z "$FLAG_WORKERS" ] && echo '  (unchanged)')"
    echo "    masters: $CUR_MASTERS -> $NEW_MASTERS$([ -z "$FLAG_MASTERS" ] && echo '  (unchanged)')"
  elif [ "$ASSUME_YES" = 1 ]; then
    NEW_WORKERS=$CUR_WORKERS NEW_MASTERS=$CUR_MASTERS
  else
    printf 'New TOTAL worker count [Enter = keep %d]: ' "$CUR_WORKERS"; read -r NEW_WORKERS; NEW_WORKERS=${NEW_WORKERS:-$CUR_WORKERS}
    printf 'New TOTAL master count [Enter = keep %d]: ' "$CUR_MASTERS"; read -r NEW_MASTERS; NEW_MASTERS=${NEW_MASTERS:-$CUR_MASTERS}
  fi
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
}
