#!/usr/bin/env bash
# functions/defcon.sh — DEFCON scenarios: a training mode that deliberately breaks a
# RUNNING lab cluster in realistic, REVERSIBLE ways so you can practise repairing it.
#
#   DEFCON 5  minor      an app is down (bad image, OOM)
#   DEFCON 4  degraded   networking / storage of an app is broken
#   DEFCON 3  serious    scheduling and node problems
#   DEFCON 2  critical   platform services (ingress, auth, DNS)
#   DEFCON 1  blackout   several platform faults at once
#
# Safety rules (by design):
#   * only reversible changes; the API server, etcd, your kubeconfig and kubeadmin
#     are NEVER touched, so you always keep the access you need to fix things;
#   * one active scenario at a time; refuses a cluster that is not healthy first;
#   * everything an injection changes is recorded in .defcon/ and can be undone
#     with --defcon-restore at any time.
# Sourced by deploy-okd.sh; not meant to be executed directly.

DEFCON_DIR=.defcon
DEFCON_NS=defcon-lab
DEFCON_IDS="imagepull oomkill svc-selector netpol pvc-pending cordon kubelet-stop router-placement bad-idp dns-upstream blackout"
DC_IMG_CLI=quay.io/openshift/origin-cli:latest
DC_IMG_HELLO=quay.io/openshifttest/hello-openshift:1.2.0
DC_WORKER_SEL='node-role.kubernetes.io/worker'

_dc_oc() { oc --request-timeout=30s "$@"; }

# ── state ─────────────────────────────────────────────────────────────────
_dc_state_get() { [ -f "$DEFCON_DIR/state" ] && grep "^$1=" "$DEFCON_DIR/state" | tail -1 | cut -d= -f2-; }
_dc_state_set() {
  mkdir -p "$DEFCON_DIR"; chmod 700 "$DEFCON_DIR"
  if [ -f "$DEFCON_DIR/state" ] && grep -q "^$1=" "$DEFCON_DIR/state"; then
    sedi -E "s|^$1=.*|$1=$2|" "$DEFCON_DIR/state"
  else echo "$1=$2" >> "$DEFCON_DIR/state"; fi
}
_dc_active() { _dc_state_get ID; }

# ── catalogue (codenames do not reveal the cause) ─────────────────────────
defcon_level() {
  case "$1" in
    imagepull|oomkill) echo 5 ;;
    svc-selector|netpol|pvc-pending) echo 4 ;;
    cordon|kubelet-stop) echo 3 ;;
    router-placement|bad-idp|dns-upstream) echo 2 ;;
    blackout) echo 1 ;;
  esac
}
defcon_codename() {
  case "$1" in
    imagepull) echo "Empty Shelf" ;;        oomkill) echo "Heavy Lifter" ;;
    svc-selector) echo "Lost Address" ;;    netpol) echo "Iron Curtain" ;;
    pvc-pending) echo "Missing Vault" ;;    cordon) echo "Locked Gates" ;;
    kubelet-stop) echo "Silent Worker" ;;   router-placement) echo "Dark Lighthouse" ;;
    bad-idp) echo "Closed Door" ;;          dns-upstream) echo "Broken Phonebook" ;;
    blackout) echo "Total Blackout" ;;
  esac
}
defcon_symptom() {
  case "$1" in
    imagepull) echo "The 'shop' application in namespace $DEFCON_NS has no running pods." ;;
    oomkill) echo "The 'api' application in namespace $DEFCON_NS keeps restarting and never stays up." ;;
    svc-selector) echo "The 'web' application in $DEFCON_NS is running, but its route returns 503 and the service has no endpoints." ;;
    netpol) echo "The 'client' pod in $DEFCON_NS can no longer reach the 'backend' service (curl http://backend:8080 hangs)." ;;
    pvc-pending) echo "The 'db' application in $DEFCON_NS is stuck Pending and its volume is never provisioned." ;;
    cordon) echo "New pods in $DEFCON_NS stay Pending: the scheduler says no node is available." ;;
    kubelet-stop) echo "One worker node has gone NotReady and its pods are being evicted." ;;
    router-placement) echo "Every application route, including the web console, is unreachable." ;;
    bad-idp) echo "The authentication cluster operator reports Degraded." ;;
    dns-upstream) echo "Pods cannot resolve external hostnames (e.g. quay.io), while in-cluster names still work." ;;
    blackout) echo "Routes and the console are down, new pods will not schedule, and pods cannot resolve external names." ;;
  esac
}
defcon_hint() {  # defcon_hint <id> <1..3>
  case "$1:$2" in
    imagepull:1) echo "Look at the pod events: oc -n $DEFCON_NS describe pod -l app=shop" ;;
    imagepull:2) echo "The status is ImagePullBackOff / ErrImagePull — is the image reference spelled correctly?" ;;
    imagepull:3) echo "Compare the tag in: oc -n $DEFCON_NS get deploy shop -o jsonpath='{.spec.template.spec.containers[0].image}'" ;;
    oomkill:1) echo "oc -n $DEFCON_NS get pods — note the restart count and the last state." ;;
    oomkill:2) echo "oc -n $DEFCON_NS describe pod -l app=api | grep -A3 'Last State' — look for OOMKilled." ;;
    oomkill:3) echo "The container's memory limit is far too low. Check resources.limits.memory on the deployment." ;;
    svc-selector:1) echo "oc -n $DEFCON_NS get endpoints web — are there any addresses?" ;;
    svc-selector:2) echo "A service only sends traffic to pods whose labels match its selector." ;;
    svc-selector:3) echo "Compare: oc -n $DEFCON_NS get svc web -o jsonpath='{.spec.selector}' with the pod labels (oc get pods --show-labels)." ;;
    netpol:1) echo "oc -n $DEFCON_NS get networkpolicy" ;;
    netpol:2) echo "A deny-all ingress policy blocks every connection to the pods it selects." ;;
    netpol:3) echo "Either delete the deny-all policy or add a policy that allows ingress to the backend from the client." ;;
    pvc-pending:1) echo "oc -n $DEFCON_NS get pvc,pods — what state is the claim in?" ;;
    pvc-pending:2) echo "oc -n $DEFCON_NS describe pvc data — read the events." ;;
    pvc-pending:3) echo "The storageClassName does not exist (oc get sc). A PVC's class cannot be edited: recreate the claim." ;;
    cordon:1) echo "oc get nodes — look at the STATUS column." ;;
    cordon:2) echo "SchedulingDisabled means the node is cordoned." ;;
    cordon:3) echo "oc adm uncordon <node> for each cordoned node." ;;
    kubelet-stop:1) echo "oc get nodes; then oc describe node <the NotReady one> — the kubelet stopped reporting." ;;
    kubelet-stop:2) echo "You cannot fix a stopped kubelet through the cluster (oc debug needs a kubelet). Think about console/API access to the VM." ;;
    kubelet-stop:3) echo "Reboot the worker VM (Hetzner console or API power cycle); systemd will start the kubelet again." ;;
    router-placement:1) echo "oc -n openshift-ingress get pods — is the router running?" ;;
    router-placement:2) echo "oc -n openshift-ingress describe pod -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default (read the scheduling event)." ;;
    router-placement:3) echo "Inspect: oc -n openshift-ingress-operator get ingresscontroller default -o yaml — look at spec.nodePlacement." ;;
    bad-idp:1) echo "oc get co authentication -o yaml — read the Degraded message." ;;
    bad-idp:2) echo "oc get oauth cluster -o yaml — look at spec.identityProviders." ;;
    bad-idp:3) echo "An identity provider references a secret in openshift-config that does not exist. Remove the entry (or create the secret)." ;;
    dns-upstream:1) echo "Test from a pod: oc -n $DEFCON_NS exec deploy/dnsprobe -- getent hosts quay.io" ;;
    dns-upstream:2) echo "oc get dns.operator default -o yaml — look at spec.upstreamResolvers." ;;
    dns-upstream:3) echo "The upstream resolver override points to an address nothing answers on. Remove spec.upstreamResolvers." ;;
    blackout:1) echo "Work top-down: what is the most visible failure? Routes/console first, then scheduling, then DNS." ;;
    blackout:2) echo "There are THREE independent faults: ingress placement, cordoned nodes, DNS upstream." ;;
    blackout:3) echo "Fix the router placement, uncordon the workers, and remove the DNS upstream override." ;;
  esac
}
defcon_solution() {
  case "$1" in
    imagepull) echo "oc -n $DEFCON_NS set image deploy/shop shop=$DC_IMG_CLI    (the tag was misspelled 'latset')" ;;
    oomkill) echo "oc -n $DEFCON_NS set resources deploy/api --limits=memory=256Mi    (limit was 16Mi)" ;;
    svc-selector) echo "oc -n $DEFCON_NS patch svc web -p '{\"spec\":{\"selector\":{\"app\":\"web\"}}}'    (selector said 'wbe')" ;;
    netpol) echo "oc -n $DEFCON_NS delete networkpolicy deny-all    (or add an allow policy for the backend)" ;;
    pvc-pending) echo "oc -n $DEFCON_NS delete deploy db pvc data, then recreate the claim with a class from 'oc get sc' (or none = default) and the deployment" ;;
    cordon) echo "oc adm uncordon \$(oc get nodes -o name)" ;;
    kubelet-stop) echo "Power-cycle the NotReady worker VM (Hetzner console/API reset); the kubelet starts on boot" ;;
    router-placement) echo "oc -n openshift-ingress-operator patch ingresscontroller/default --type=merge -p '{\"spec\":{\"nodePlacement\":{\"nodeSelector\":{\"matchLabels\":{\"$DC_WORKER_SEL\":\"\"}}}}}'" ;;
    bad-idp) echo "Remove the 'defcon-corp-ldap' entry from oauth/cluster spec.identityProviders (oc edit oauth cluster)" ;;
    dns-upstream) echo "oc patch dns.operator default --type=merge -p '{\"spec\":{\"upstreamResolvers\":null}}'" ;;
    blackout) echo "router-placement + cordon + dns-upstream fixes together (see those scenarios)" ;;
  esac
}

# ── helpers ───────────────────────────────────────────────────────────────
_dc_ns() {
  _dc_oc get ns "$DEFCON_NS" >/dev/null 2>&1 || _dc_oc create ns "$DEFCON_NS" >/dev/null
  _dc_oc label ns "$DEFCON_NS" defcon=lab --overwrite >/dev/null 2>&1 || true
}
_dc_avail() {  # available replicas of a deployment in the lab namespace (0 if none)
  local n; n=$(_dc_oc -n "$DEFCON_NS" get deploy "$1" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  echo "${n:-0}"
}
_dc_to_mi() {  # k8s quantity -> whole MiB
  case "$1" in
    *Gi) echo $(( ${1%Gi} * 1024 )) ;;
    *Mi) echo "${1%Mi}" ;;
    *Ki) echo $(( ${1%Ki} / 1024 )) ;;
    ""|*[!0-9]*) echo 0 ;;
    *) echo $(( $1 / 1048576 )) ;;
  esac
}
_dc_workers() {  # schedulable-role nodes (have the worker role)
  _dc_oc get nodes -l "$DC_WORKER_SEL" -o name 2>/dev/null | sed 's|node/||'
}
_dc_pure_workers() {  # worker-only nodes (not also masters)
  _dc_oc get nodes -l "$DC_WORKER_SEL,!node-role.kubernetes.io/master" -o name 2>/dev/null | sed 's|node/||'
}
_dc_wait_rollout() { _dc_oc -n "$DEFCON_NS" rollout status "deploy/$1" --timeout="${2:-150s}" >/dev/null 2>&1; }

# ── injections ────────────────────────────────────────────────────────────
_dc_inject_imagepull() {
  _dc_ns
  _dc_oc -n "$DEFCON_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: shop}
spec:
  replicas: 1
  selector: {matchLabels: {app: shop}}
  template:
    metadata: {labels: {app: shop}}
    spec:
      containers:
      - name: shop
        image: quay.io/openshift/origin-cli:latset
        command: ["sh","-c","sleep infinity"]
EOF
}
_dc_inject_oomkill() {
  _dc_ns
  _dc_oc -n "$DEFCON_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: api}
spec:
  replicas: 1
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      containers:
      - name: api
        image: $DC_IMG_CLI
        command: ["sh","-c","head -c 120M /dev/zero | tail -c 120M >/dev/null; sleep infinity"]
        resources:
          limits: {memory: 16Mi}
          requests: {memory: 16Mi}
EOF
}
_dc_inject_svc_selector() {
  _dc_ns
  _dc_oc -n "$DEFCON_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 1
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      containers:
      - name: web
        image: $DC_IMG_HELLO
        ports: [{containerPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec:
  selector: {app: wbe}
  ports: [{port: 8080, targetPort: 8080}]
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: web}
spec:
  to: {kind: Service, name: web}
  port: {targetPort: 8080}
EOF
}
_dc_inject_netpol() {
  _dc_ns
  _dc_oc -n "$DEFCON_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: backend}
spec:
  replicas: 1
  selector: {matchLabels: {app: backend}}
  template:
    metadata: {labels: {app: backend}}
    spec:
      containers:
      - name: backend
        image: $DC_IMG_HELLO
        ports: [{containerPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: backend}
spec:
  selector: {app: backend}
  ports: [{port: 8080, targetPort: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: client}
spec:
  replicas: 1
  selector: {matchLabels: {app: client}}
  template:
    metadata: {labels: {app: client}}
    spec:
      containers:
      - name: client
        image: $DC_IMG_CLI
        command: ["sh","-c","sleep infinity"]
EOF
  _dc_wait_rollout backend; _dc_wait_rollout client
  _dc_oc -n "$DEFCON_NS" apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all}
spec:
  podSelector: {}
  policyTypes: [Ingress]
EOF
}
_dc_inject_pvc_pending() {
  _dc_ns
  _dc_oc -n "$DEFCON_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: fast-ssd-nonexistent
  resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: db}
spec:
  replicas: 1
  selector: {matchLabels: {app: db}}
  template:
    metadata: {labels: {app: db}}
    spec:
      containers:
      - name: db
        image: $DC_IMG_CLI
        command: ["sh","-c","sleep infinity"]
        volumeMounts: [{name: data, mountPath: /data}]
      volumes:
      - name: data
        persistentVolumeClaim: {claimName: data}
EOF
}
_dc_inject_cordon() {
  local n
  _dc_ns
  : > "$DEFCON_DIR/cordoned"
  for n in $(_dc_workers); do
    _dc_oc adm cordon "$n" >/dev/null 2>&1 && echo "$n" >> "$DEFCON_DIR/cordoned"
  done
  _dc_oc -n "$DEFCON_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: batch}
spec:
  replicas: 3
  selector: {matchLabels: {app: batch}}
  template:
    metadata: {labels: {app: batch}}
    spec:
      containers:
      - name: batch
        image: $DC_IMG_CLI
        command: ["sh","-c","sleep infinity"]
EOF
}
_dc_inject_kubelet_stop() {
  local n
  n=$(_dc_pure_workers | tail -1)
  [ -n "$n" ] || return 1
  echo "$n" > "$DEFCON_DIR/kubelet-node"
  _dc_oc debug "node/$n" -- chroot /host systemctl stop kubelet >/dev/null 2>&1 || true
}
_dc_inject_router_placement() {
  _dc_oc -n openshift-ingress-operator get ingresscontroller default -o json 2>/dev/null \
    | jq -c '.spec.nodePlacement // null' > "$DEFCON_DIR/router.orig"
  _dc_oc -n openshift-ingress-operator patch ingresscontroller/default --type=merge \
    -p '{"spec":{"nodePlacement":{"nodeSelector":{"matchLabels":{"defcon":"nowhere"}}}}}' >/dev/null
  # make sure the outage is real: recreate the router pods so they go Pending
  sleep 5
  _dc_oc -n openshift-ingress delete pods --all --wait=false >/dev/null 2>&1 || true
}
_dc_inject_bad_idp() {
  local orig
  orig=$(_dc_oc get oauth cluster -o json 2>/dev/null | jq -c '.spec.identityProviders // []')
  echo "$orig" > "$DEFCON_DIR/oauth.orig"
  _dc_oc patch oauth cluster --type=merge -p "$(echo "$orig" | jq -c '{spec:{identityProviders:(. + [{name:"defcon-corp-ldap",mappingMethod:"claim",type:"HTPasswd",htpasswd:{fileData:{name:"defcon-missing-htpasswd"}}}])}}')" >/dev/null
}
_dc_inject_dns_upstream() {
  _dc_ns
  _dc_oc -n "$DEFCON_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: dnsprobe}
spec:
  replicas: 1
  selector: {matchLabels: {app: dnsprobe}}
  template:
    metadata: {labels: {app: dnsprobe}}
    spec:
      containers:
      - name: dnsprobe
        image: $DC_IMG_CLI
        command: ["sh","-c","sleep infinity"]
EOF
  _dc_wait_rollout dnsprobe
  _dc_oc get dns.operator default -o json 2>/dev/null | jq -c '.spec.upstreamResolvers // null' > "$DEFCON_DIR/dns.orig"
  _dc_oc patch dns.operator default --type=merge \
    -p '{"spec":{"upstreamResolvers":{"policy":"Sequential","upstreams":[{"type":"Network","address":"192.0.2.53","port":53}]}}}' >/dev/null
}
_dc_inject_blackout() {
  _dc_inject_router_placement
  _dc_inject_cordon
  _dc_inject_dns_upstream
}

# ── health checks (0 = the fault is repaired) ─────────────────────────────
_dc_check_imagepull()    { [ "$(_dc_avail shop)" -ge 1 ]; }
_dc_check_oomkill() {
  local lim; lim=$(_dc_oc -n "$DEFCON_NS" get deploy api -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)
  [ "$(_dc_to_mi "$lim")" -ge 128 ] && [ "$(_dc_avail api)" -ge 1 ]
}
_dc_check_svc_selector() {
  local ip; ip=$(_dc_oc -n "$DEFCON_NS" get endpoints web -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  [ -n "$ip" ]
}
_dc_check_netpol() {
  local out
  out=$(_dc_oc -n "$DEFCON_NS" exec deploy/client -- curl -s -m 4 http://backend:8080 2>/dev/null)
  case "$out" in *Hello*) return 0 ;; esac
  return 1
}
_dc_check_pvc_pending() {
  local ph; ph=$(_dc_oc -n "$DEFCON_NS" get pvc data -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$ph" = Bound ] && [ "$(_dc_avail db)" -ge 1 ]
}
_dc_check_cordon() {
  local n u
  [ -s "$DEFCON_DIR/cordoned" ] || return 1
  while read -r n; do
    u=$(_dc_oc get node "$n" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)
    [ "$u" = true ] && return 1
  done < "$DEFCON_DIR/cordoned"
  [ "$(_dc_avail batch)" -ge 1 ]
}
_dc_check_kubelet_stop() {
  local n st; n=$(cat "$DEFCON_DIR/kubelet-node" 2>/dev/null)
  [ -n "$n" ] || return 1
  st=$(_dc_oc get node "$n" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)
  [ "$st" = True ]
}
_dc_check_router_placement() {
  local sel r
  sel=$(_dc_oc -n openshift-ingress-operator get ingresscontroller default -o jsonpath='{.spec.nodePlacement.nodeSelector.matchLabels.defcon}' 2>/dev/null)
  [ -z "$sel" ] || return 1
  r=$(_dc_oc -n openshift-ingress get deploy router-default -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  [ "${r:-0}" -ge 1 ]
}
_dc_check_bad_idp() {
  _dc_oc get oauth cluster -o json 2>/dev/null | jq -e '[.spec.identityProviders[]?.name] | index("defcon-corp-ldap") | not' >/dev/null 2>&1 && return 0
  _dc_oc -n openshift-config get secret defcon-missing-htpasswd >/dev/null 2>&1
}
_dc_check_dns_upstream() {
  local ups
  ups=$(_dc_oc get dns.operator default -o jsonpath='{.spec.upstreamResolvers.upstreams[*].address}' 2>/dev/null)
  case "$ups" in *192.0.2.53*) return 1 ;; esac
  _dc_oc -n "$DEFCON_NS" exec deploy/dnsprobe -- sh -c 'timeout 8 getent hosts quay.io >/dev/null' >/dev/null 2>&1
}
_dc_check_blackout() {
  _dc_check_router_placement && _dc_check_cordon && _dc_check_dns_upstream
}

# ── restore (idempotent; also the "give up" path) ─────────────────────────
_dc_restore_router_placement() {
  local orig; orig=$(cat "$DEFCON_DIR/router.orig" 2>/dev/null)
  if [ -z "$orig" ] || [ "$orig" = null ]; then
    orig="{\"nodeSelector\":{\"matchLabels\":{\"$DC_WORKER_SEL\":\"\"}}}"   # this repo's standard placement
  fi
  _dc_oc -n openshift-ingress-operator patch ingresscontroller/default --type=merge \
    -p "{\"spec\":{\"nodePlacement\":$orig}}" >/dev/null 2>&1 || true
}
_dc_restore_cordon() {
  local n
  [ -s "$DEFCON_DIR/cordoned" ] || return 0
  while read -r n; do _dc_oc adm uncordon "$n" >/dev/null 2>&1 || true; done < "$DEFCON_DIR/cordoned"
}
_dc_restore_kubelet_stop() {
  local n id t=0; n=$(cat "$DEFCON_DIR/kubelet-node" 2>/dev/null)
  [ -n "$n" ] || return 0
  id=$(curl -s -m 20 -H "Authorization: Bearer $HCLOUD_TOKEN" "https://api.hetzner.cloud/v1/servers?name=$n" | jq -r '.servers[0].id // empty')
  [ -n "$id" ] && curl -s -m 20 -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" "https://api.hetzner.cloud/v1/servers/$id/actions/reset" >/dev/null
  echo "    rebooting $n — waiting for it to become Ready ..."
  while [ $t -lt 30 ]; do
    _dc_check_kubelet_stop && return 0
    sleep 20; t=$((t+1))
  done
}
_dc_restore_bad_idp() {
  local orig; orig=$(cat "$DEFCON_DIR/oauth.orig" 2>/dev/null)
  [ -n "$orig" ] || orig='[]'
  _dc_oc patch oauth cluster --type=merge -p "{\"spec\":{\"identityProviders\":$orig}}" >/dev/null 2>&1 || true
}
_dc_restore_dns_upstream() {
  local orig; orig=$(cat "$DEFCON_DIR/dns.orig" 2>/dev/null)
  [ -n "$orig" ] || orig=null
  _dc_oc patch dns.operator default --type=merge -p "{\"spec\":{\"upstreamResolvers\":$orig}}" >/dev/null 2>&1 || true
}
defcon_restore() {  # defcon_restore <id> — undo everything the scenario changed
  case "$1" in
    router-placement) _dc_restore_router_placement ;;
    cordon) _dc_restore_cordon ;;
    kubelet-stop) _dc_restore_kubelet_stop ;;
    bad-idp) _dc_restore_bad_idp ;;
    dns-upstream) _dc_restore_dns_upstream ;;
    blackout) _dc_restore_router_placement; _dc_restore_cordon; _dc_restore_dns_upstream ;;
  esac
  _dc_oc delete ns "$DEFCON_NS" --wait=false >/dev/null 2>&1 || true
}

# ── prerequisites and safety ──────────────────────────────────────────────
_dc_prereq() {  # _dc_prereq <id> — prints why a scenario cannot run, returns 1
  local w
  case "$1" in
    kubelet-stop)
      w=$(_dc_pure_workers | wc -l | tr -d ' ')
      [ "${w:-0}" -ge 2 ] || { echo "needs at least 2 worker-only nodes (found ${w:-0}) so the cluster keeps serving traffic"; return 1; } ;;
    cordon|blackout)
      w=$(_dc_workers | wc -l | tr -d ' ')
      [ "${w:-0}" -ge 1 ] || { echo "needs at least one node with the worker role"; return 1; } ;;
    pvc-pending)
      _dc_oc get sc -o name 2>/dev/null | grep -q . || { echo "needs a storage class in the cluster (install one, e.g. --devops with a storage backend)"; return 1; } ;;
  esac
  return 0
}
_dc_healthy() {  # every cluster operator Available and not Degraded
  local bad
  bad=$(_dc_oc get co --no-headers 2>/dev/null | awk '$3!="True" || $5=="True" {print $1}')
  [ -z "$bad" ] || { echo "cluster is not healthy — these operators are unavailable/degraded: $(echo $bad | tr '\n' ' ')"; return 1; }
}

# ── commands ──────────────────────────────────────────────────────────────
defcon_list() {
  local id
  echo
  echo "DEFCON scenarios — practise repairing a deliberately broken lab cluster"
  echo "  (reversible; API server, etcd and your kubeconfig are never touched)"
  echo
  printf '  %-3s %-16s %-16s %s\n' "LVL" "SCENARIO" "CODENAME" "WHAT YOU WILL SEE"
  for id in $DEFCON_IDS; do
    printf '  %-3s %-16s %-16s %s\n' "$(defcon_level "$id")" "$id" "$(defcon_codename "$id")" "$(defcon_symptom "$id" | cut -c1-78)"
  done | sort -k1,1nr
  echo
  echo "  ./deploy-okd.sh --defcon-scenario <id|random>   start one"
  echo "  ./deploy-okd.sh --defcon-status                  current mission + health check"
  echo "  ./deploy-okd.sh --defcon-hint                    next hint (3 per scenario)"
  echo "  ./deploy-okd.sh --defcon-check                   verify your repair"
  echo "  ./deploy-okd.sh --defcon-solve                   show the answer"
  echo "  ./deploy-okd.sh --defcon-restore                 undo everything, back to normal"
}

defcon_start() {  # defcon_start <id|random>
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  local id=$1 cand list reason
  command -v jq >/dev/null 2>&1 || { err "jq is required for DEFCON scenarios"; return 1; }
  oc whoami >/dev/null 2>&1 || { echo "    cannot reach the cluster — is it running?"; return 1; }
  if [ -n "$(_dc_active)" ]; then
    echo "    a scenario is already active: $(_dc_active) — finish it (--defcon-check) or run --defcon-restore first"; return 1
  fi
  if [ "$id" = random ]; then
    list=""
    for cand in $DEFCON_IDS; do _dc_prereq "$cand" >/dev/null 2>&1 && list="$list $cand"; done
    [ -n "$list" ] || { echo "    no scenario can run on this cluster"; return 1; }
    id=$(echo $list | tr ' ' '\n' | awk 'BEGIN{srand()}{a[NR]=$0}END{print a[int(rand()*NR)+1]}')
  fi
  case " $DEFCON_IDS " in *" $id "*) ;; *) echo "    unknown scenario '$id' — see --defcon-list"; return 1 ;; esac
  reason=$(_dc_prereq "$id") || { echo "    scenario '$id' cannot run here: $reason"; return 1; }
  reason=$(_dc_healthy) || { echo "    $reason"; echo "    (start from a healthy cluster so you know every problem is part of the exercise)"; return 1; }

  if [ "${ASSUME_YES:-0}" != 1 ]; then
    echo
    echo "  This will deliberately BREAK part of the cluster ($DOMAIN) at DEFCON $(defcon_level "$id")."
    echo "  It is reversible (--defcon-restore), and API/etcd/kubeconfig are never touched."
    printf '  Type BREAK to continue: '
    read -r ans; [ "$ans" = BREAK ] || { echo "  Aborted."; return 1; }
  fi

  mkdir -p "$DEFCON_DIR"; chmod 700 "$DEFCON_DIR"; rm -f "$DEFCON_DIR"/*.orig "$DEFCON_DIR/cordoned" "$DEFCON_DIR/kubelet-node"
  : > "$DEFCON_DIR/state"
  _dc_state_set DOMAIN "$DOMAIN"
  _dc_state_set ID "$id"
  _dc_state_set START "$(date +%s)"
  _dc_state_set HINTS 0

  log "DEFCON $(defcon_level "$id") — Operation $(defcon_codename "$id")"
  local fn=_dc_inject_$(echo "$id" | tr '-' '_')
  if ! $fn; then
    echo "    injection failed — restoring"; defcon_restore "$id"; rm -f "$DEFCON_DIR/state"; return 1
  fi
  echo
  echo "  ┌─ MISSION BRIEFING ───────────────────────────────────────────────"
  echo "  │  $(defcon_symptom "$id")"
  echo "  │  Objective: find the cause and repair it. Nothing was deleted permanently."
  echo "  │  KUBECONFIG=$PWD/ignition/auth/kubeconfig"
  echo "  │  Stuck?   ./deploy-okd.sh --defcon-hint     Done?  ./deploy-okd.sh --defcon-check"
  echo "  └────────────────────────────────────────────────────────────────"
  return 0
}

defcon_status() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  local id; id=$(_dc_active)
  [ -n "$id" ] || { echo "    no active scenario — start one with --defcon-scenario <id|random>"; return 0; }
  local start elapsed hints
  start=$(_dc_state_get START); elapsed=$(( $(date +%s) - start )); hints=$(_dc_state_get HINTS)
  echo
  echo "  DEFCON $(defcon_level "$id") — Operation $(defcon_codename "$id")   (${elapsed}s elapsed, ${hints:-0} hint(s) used)"
  echo "  $(defcon_symptom "$id")"
  if "_dc_check_$(echo "$id" | tr '-' '_')"; then echo "  Status: REPAIRED — run --defcon-check to record it"; else echo "  Status: still broken"; fi
}

defcon_next_hint() {
  local id n; id=$(_dc_active)
  [ -n "$id" ] || { echo "    no active scenario"; return 0; }
  n=$(( $(_dc_state_get HINTS) + 1 ))
  if [ "$n" -gt 3 ]; then echo "    no more hints — use --defcon-solve to see the answer"; return 0; fi
  _dc_state_set HINTS "$n"
  echo "  Hint $n/3: $(defcon_hint "$id" "$n")"
}

defcon_check() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  local id start secs hints; id=$(_dc_active)
  [ -n "$id" ] || { echo "    no active scenario"; return 0; }
  if "_dc_check_$(echo "$id" | tr '-' '_')"; then
    start=$(_dc_state_get START); secs=$(( $(date +%s) - start )); hints=$(_dc_state_get HINTS)
    echo
    echo "  ✔ Repaired! DEFCON $(defcon_level "$id") — Operation $(defcon_codename "$id")"
    echo "    time: ${secs}s   hints used: ${hints:-0}"
    echo "$(date '+%Y-%m-%d %H:%M') $DOMAIN $id level=$(defcon_level "$id") time=${secs}s hints=${hints:-0}" >> "$DEFCON_DIR/scores"
    _dc_oc delete ns "$DEFCON_NS" --wait=false >/dev/null 2>&1 || true
    rm -f "$DEFCON_DIR/state" "$DEFCON_DIR"/*.orig "$DEFCON_DIR/cordoned" "$DEFCON_DIR/kubelet-node"
    return 0
  fi
  echo "  ✘ Not fixed yet. (--defcon-hint for a nudge, --defcon-status to see the symptom again)"
  return 1
}

defcon_solve() {
  local id; id=$(_dc_active)
  [ -n "$id" ] || { echo "    no active scenario"; return 0; }
  echo "  Solution for $id:"; echo "    $(defcon_solution "$id")"
  echo "  (this scenario stays active; --defcon-restore reverts it for you)"
}

defcon_restore_active() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  local id; id=$(_dc_active)
  [ -n "$id" ] || { echo "    no active scenario — nothing to restore"; return 0; }
  log "Restoring after scenario $id"
  defcon_restore "$id"
  rm -f "$DEFCON_DIR/state" "$DEFCON_DIR"/*.orig "$DEFCON_DIR/cordoned" "$DEFCON_DIR/kubelet-node"
  echo "    restored — the cluster is back to normal"
}

defcon_menu() {
  local id sel i list=""
  defcon_list
  echo
  echo "  Pick a scenario (id, number, or 'random'; Enter = cancel):"
  i=1
  for id in $DEFCON_IDS; do
    printf '   %2d) %-16s DEFCON %s  %s\n' "$i" "$id" "$(defcon_level "$id")" "$(defcon_codename "$id")"; i=$((i+1))
  done
  printf '  Selection: '
  read -r sel
  [ -n "$sel" ] || return 0
  case "$sel" in *[!0-9]*) id=$sel ;; *) id=$(echo $DEFCON_IDS | awk -v n="$sel" '{print $n}') ;; esac
  defcon_start "$id"
}

# entry point: FLAG_DEFCON is the action (menu|list|scenario|status|hint|check|solve|restore)
run_defcon() {
  case "${FLAG_DEFCON:-menu}" in
    list) defcon_list ;;
    scenario) defcon_start "${FLAG_DEFCON_ID:-random}" ;;
    status) defcon_status ;;
    hint) defcon_next_hint ;;
    check) defcon_check ;;
    solve) defcon_solve ;;
    restore) defcon_restore_active ;;
    *) defcon_menu ;;
  esac
}
