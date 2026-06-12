#!/usr/bin/env bash
# functions/watchdog.sh — CSR approval + apiserver rollout watchdog during install
# Sourced by deploy-okd.sh; not meant to be executed directly.

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
