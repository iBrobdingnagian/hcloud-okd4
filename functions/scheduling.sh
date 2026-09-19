#!/usr/bin/env bash
# functions/scheduling.sh — keep node roles consistent with the topology:
#   0 workers  -> masters are schedulable and carry the worker role (single node)
#   >=1 worker -> masters are control-plane only; only workers carry the worker role
# The worker role on a master is cluster-wide (scheduler mastersSchedulable), so
# one patch changes all masters at once. Sourced by deploy-okd.sh; not executable.

# oc with retries: the API restarts kube-apiserver revisions during/after install
_oc_retry() {
  local i
  for i in 1 2 3 4 5 6; do
    oc --request-timeout=20s "$@" 2>/dev/null && return 0
    sleep 10
  done
  return 1
}

# set_masters_schedulable true|false
set_masters_schedulable() {
  local want=$1
  _oc_retry patch schedulers.config.openshift.io cluster --type=merge \
    -p "{\"spec\":{\"mastersSchedulable\":$want}}" >/dev/null \
    || { echo "    WARNING: could not set mastersSchedulable=$want — run: oc patch schedulers.config.openshift.io cluster --type=merge -p '{\"spec\":{\"mastersSchedulable\":$want}}'"; return 1; }
  echo "    mastersSchedulable=$want"
}

# node_roles_ok <worker-count> — 0 if every node's roles match the topology
node_roles_ok() {
  local workers=$1 bad=0 n roles
  while read -r n roles; do
    [ -n "$n" ] || continue
    case ",$roles," in *,control-plane,*|*,master,*) is_master=1 ;; *) is_master=0 ;; esac
    case ",$roles," in *,worker,*) has_worker=1 ;; *) has_worker=0 ;; esac
    if [ "$is_master" = 1 ]; then
      if [ "$workers" -gt 0 ] && [ "$has_worker" = 1 ]; then bad=1; fi
      if [ "$workers" -eq 0 ] && [ "$has_worker" = 0 ]; then bad=1; fi
    else
      [ "$has_worker" = 1 ] || bad=1
    fi
  done < <(oc --request-timeout=20s get nodes --no-headers 2>/dev/null | awk '{print $1, $3}')
  return $bad
}

# place_router <worker-count> — pin the default router to worker nodes.
# A cluster installed with 0 workers has infrastructureTopology=SingleReplica, and
# the ingress operator then puts the router on MASTERS (node-role...master=) for the
# life of the cluster. Once masters become control-plane only (tainted) that router
# has nowhere to run and every route, including the console, goes down. Selecting
# the worker role works in both topologies: a schedulable master also carries it.
place_router() {
  local workers=$1 replicas=1
  [ "$workers" -ge 2 ] && replicas=2
  _oc_retry -n openshift-ingress-operator patch ingresscontroller/default --type=merge \
    -p "{\"spec\":{\"replicas\":$replicas,\"nodePlacement\":{\"nodeSelector\":{\"matchLabels\":{\"node-role.kubernetes.io/worker\":\"\"}}}}}" >/dev/null \
    || { echo "    WARNING: could not move the router to worker nodes — run: oc -n openshift-ingress-operator patch ingresscontroller/default --type=merge -p '{\"spec\":{\"nodePlacement\":{\"nodeSelector\":{\"matchLabels\":{\"node-role.kubernetes.io/worker\":\"\"}}}}}'"; return 1; }
  echo "    router -> worker nodes ($replicas replica(s))"
  # wait until the router runs on the new nodes before anything is tainted
  _oc_retry -n openshift-ingress rollout status deployment/router-default --timeout=240s >/dev/null \
    || echo "    WARNING: router rollout not finished yet — check: oc -n openshift-ingress get pods"
}

# apply_node_roles <worker-count> — router first, then flip the setting, then verify
apply_node_roles() {
  local workers=$1 want=true tries=0
  [ "$workers" -gt 0 ] && want=false
  log "Node roles: $workers worker(s) -> masters $([ "$want" = true ] && echo 'schedulable (worker role kept)' || echo 'control-plane only (worker role removed)')"
  # ORDER MATTERS: the router must already be on workers before masters are tainted
  place_router "$workers" || return 1
  set_masters_schedulable "$want" || return 1
  while [ $tries -lt 18 ]; do
    node_roles_ok "$workers" && break
    tries=$((tries+1)); sleep 10
  done
  oc --request-timeout=20s get nodes 2>/dev/null
  if node_roles_ok "$workers"; then
    echo "    node roles OK"
  else
    echo "    WARNING: node roles do not match the topology yet — check: oc get nodes"
    return 1
  fi
}
