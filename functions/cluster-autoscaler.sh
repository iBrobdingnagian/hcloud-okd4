#!/usr/bin/env bash
# functions/cluster-autoscaler.sh — Kubernetes Cluster Autoscaler with the
# native Hetzner cloud provider (uses the Hetzner API directly).
#
# WHY NOT MachineAutoscaler? OpenShift's MachineAutoscaler scales MachineSets,
# which need a cloud Machine controller. This cluster is platform "none" (UPI)
# and Hetzner has no OpenShift Machine provider, so there are no Machines /
# MachineSets and MachineAutoscaler cannot run. The upstream cluster-autoscaler
# ships a `hetzner` cloud provider that talks to the Hetzner API directly — that
# is the "machine autoscaler" that works here.
#
# It watches for Pending pods and creates servers in a node pool (and deletes
# under-used ones). New servers boot FCOS from ignition/worker.ign (the worker
# pointer to api-int:22623/config/worker) and join the cluster; because
# platform "none" won't auto-approve CSRs for nodes with no backing Machine, we
# also deploy a small CSR auto-approver so the new nodes reach Ready unattended.
#
# Node-pool flag format (cluster-autoscaler 1.29 hetzner provider):
#   --nodes=<min>:<max>:<server-type>:<region>:<pool-name>
#
# Sourced by deploy-okd.sh; not meant to be executed directly.

CA_NS=cluster-autoscaler
# NB: the Hetzner provider in 1.29.x / 1.30.0 / 1.31.0 hardcodes an internal
# "draining-node-pool" with the long-retired server type cx11, which makes every
# autoscaling cycle fail ("server type not found"). That bug is removed in
# 1.30.3 / 1.31.1 / 1.32+, so we default to 1.30.3 (closest to the cluster's
# k8s 1.29; cluster-autoscaler tolerates being a minor ahead).
CA_VERSION_DEFAULT=v1.30.3

install_cluster_autoscaler() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  command -v jq >/dev/null 2>&1 || { err "jq is required for --cluster-autoscaler"; return 1; }
  [ -n "$HCLOUD_TOKEN" ] || { err "HCLOUD_TOKEN is not set (.env)"; return 1; }
  oc whoami >/dev/null 2>&1 || { echo "    cannot reach the cluster — is it running?"; return 1; }
  [ -f ignition/worker.ign ] || { err "ignition/worker.ign not found — it is the node cloud-init"; return 1; }

  # ── pool parameters (flags or defaults) ───────────────────────────────
  # default the pool to the SAME server type the existing workers run (so
  # autoscaled nodes match the cluster); fall back to cx33 if unknown
  local pooltype=${FLAG_CA_TYPE:-${TF_VAR_server_type_worker:-cx33}} pmin=${FLAG_CA_MIN:-0} pmax=${FLAG_CA_MAX:-3}
  local pool=autoscaled loc=${TF_VAR_location:-nbg1} net=${DOMAIN} cav=${CA_VERSION:-$CA_VERSION_DEFAULT}
  case "$pmin$pmax" in *[!0-9]*) err "--ca-min/--ca-max must be numbers"; return 1;; esac
  [ "$pmax" -ge "$pmin" ] || { err "--ca-max ($pmax) must be >= --ca-min ($pmin)"; return 1; }

  # ── discover the cluster's FCOS snapshot, ssh key, base firewall ───────
  local img sshkey fw cli b64init
  img=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
    "https://api.hetzner.cloud/v1/images?type=snapshot&status=available&label_selector=os=fcos,fcos_release=${TF_VAR_fcos_release}" \
    | jq -r '.images | sort_by(.created) | last | .id // empty')
  [ -n "$img" ] || { err "could not find the FCOS snapshot (os=fcos,fcos_release=${TF_VAR_fcos_release})"; return 1; }
  sshkey=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" "https://api.hetzner.cloud/v1/ssh_keys" | jq -r '.ssh_keys[0].name // empty')
  fw="${DOMAIN}-base"   # the cluster-internal firewall workers carry
  cli=$(oc -n openshift get istag cli:latest -o jsonpath='{.image.dockerImageReference}' 2>/dev/null)
  [ -n "$cli" ] || cli=quay.io/openshift/origin-cli:latest
  # HCLOUD_CLOUD_INIT must be base64 of the node userdata (the worker ignition)
  b64init=$(base64 < ignition/worker.ign | tr -d '\n')

  log "Installing Cluster Autoscaler (Hetzner cloud provider) — EXPERIMENTAL"
  echo "    pool '$pool': type=$pooltype region=$loc min=$pmin max=$pmax"
  echo "    FCOS snapshot=$img  network=$net  firewall=$fw  sshkey=${sshkey:-none}  image=$cav"
  echo "    cloud-init = ignition/worker.ign (worker pointer -> api-int:22623/config/worker)"

  oc get ns "$CA_NS" >/dev/null 2>&1 || oc create namespace "$CA_NS" >/dev/null

  # ── secret: token + base64 cloud-init ─────────────────────────────────
  oc -n "$CA_NS" create secret generic hcloud \
    --from-literal=HCLOUD_TOKEN="$HCLOUD_TOKEN" \
    --from-literal=HCLOUD_CLOUD_INIT="$b64init" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null

  # ── RBAC (standard cluster-autoscaler) + the autoscaler Deployment ─────
  oc apply -f - >/dev/null <<RBAC
apiVersion: v1
kind: ServiceAccount
metadata: { name: cluster-autoscaler, namespace: ${CA_NS} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: hcloud-cluster-autoscaler }
rules:
- apiGroups: [""]
  resources: ["events","endpoints"]
  verbs: ["create","patch"]
- apiGroups: [""]
  resources: ["pods/eviction"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["pods/status"]
  verbs: ["update"]
- apiGroups: [""]
  resources: ["endpoints"]
  resourceNames: ["cluster-autoscaler"]
  verbs: ["get","update"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["watch","list","get","update"]
- apiGroups: [""]
  resources: ["namespaces","pods","services","replicationcontrollers","persistentvolumeclaims","persistentvolumes"]
  verbs: ["watch","list","get"]
- apiGroups: ["batch","extensions"]
  resources: ["jobs"]
  verbs: ["get","list","watch","patch"]
- apiGroups: ["batch"]
  resources: ["cronjobs"]
  verbs: ["get","list","watch"]
- apiGroups: ["extensions","apps"]
  resources: ["daemonsets","replicasets","statefulsets"]
  verbs: ["watch","list","get"]
- apiGroups: ["policy"]
  resources: ["poddisruptionbudgets"]
  verbs: ["watch","list"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses","csinodes","csidrivers","csistoragecapacities","volumeattachments"]
  verbs: ["watch","list","get"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["create"]
- apiGroups: ["coordination.k8s.io"]
  resourceNames: ["cluster-autoscaler"]
  resources: ["leases"]
  verbs: ["get","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: hcloud-cluster-autoscaler }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: hcloud-cluster-autoscaler }
subjects:
- { kind: ServiceAccount, name: cluster-autoscaler, namespace: ${CA_NS} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: cluster-autoscaler, namespace: ${CA_NS} }
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create","list","watch"]
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["cluster-autoscaler-status"]
  verbs: ["delete","get","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: cluster-autoscaler, namespace: ${CA_NS} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: cluster-autoscaler }
subjects:
- { kind: ServiceAccount, name: cluster-autoscaler, namespace: ${CA_NS} }
RBAC

  oc apply -f - >/dev/null <<CADEP
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-autoscaler
  namespace: ${CA_NS}
  labels: { app: cluster-autoscaler }
spec:
  replicas: 1
  selector: { matchLabels: { app: cluster-autoscaler } }
  template:
    metadata: { labels: { app: cluster-autoscaler } }
    spec:
      serviceAccountName: cluster-autoscaler
      priorityClassName: system-cluster-critical
      containers:
      - name: cluster-autoscaler
        image: registry.k8s.io/autoscaling/cluster-autoscaler:${cav}
        command:
        - ./cluster-autoscaler
        - --cloud-provider=hetzner
        - --namespace=${CA_NS}
        - --nodes=${pmin}:${pmax}:${pooltype}:${loc}:${pool}
        - --stderrthreshold=info
        - --scale-down-enabled=true
        - --scale-down-delay-after-add=10m
        - --scale-down-unneeded-time=10m
        - --scan-interval=30s
        - --expander=least-waste
        env:
        - { name: HCLOUD_TOKEN,       valueFrom: { secretKeyRef: { name: hcloud, key: HCLOUD_TOKEN } } }
        - { name: HCLOUD_CLOUD_INIT,  valueFrom: { secretKeyRef: { name: hcloud, key: HCLOUD_CLOUD_INIT } } }
        - { name: HCLOUD_IMAGE,       value: "${img}" }
        - { name: HCLOUD_NETWORK,     value: "${net}" }
        - { name: HCLOUD_FIREWALL,    value: "${fw}" }
        - { name: HCLOUD_SSH_KEY,     value: "${sshkey}" }
        - { name: HCLOUD_PUBLIC_IPV4, value: "true" }
        - { name: HCLOUD_PUBLIC_IPV6, value: "true" }
        resources:
          requests: { cpu: 100m, memory: 300Mi }
          limits:   { memory: 500Mi }
CADEP

  # ── CSR auto-approver (platform "none" won't auto-approve node CSRs) ────
  oc apply -f - >/dev/null <<CSR
apiVersion: v1
kind: ServiceAccount
metadata: { name: csr-approver, namespace: ${CA_NS} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: hcloud-csr-approver }
rules:
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests"]
  verbs: ["get","list","watch"]
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests/approval"]
  verbs: ["update"]
- apiGroups: ["certificates.k8s.io"]
  resources: ["signers"]
  resourceNames: ["kubernetes.io/kube-apiserver-client-kubelet","kubernetes.io/kubelet-serving"]
  verbs: ["approve"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: hcloud-csr-approver }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: hcloud-csr-approver }
subjects:
- { kind: ServiceAccount, name: csr-approver, namespace: ${CA_NS} }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: csr-approver
  namespace: ${CA_NS}
  labels: { app: csr-approver }
spec:
  replicas: 1
  selector: { matchLabels: { app: csr-approver } }
  template:
    metadata: { labels: { app: csr-approver } }
    spec:
      serviceAccountName: csr-approver
      containers:
      - name: approver
        image: ${cli}
        command: ["/bin/sh","-c"]
        args:
        - |
          echo "csr-approver: approving pending kubelet CSRs every 20s"
          while true; do
            pending=\$(oc get csr -o go-template='{{range .items}}{{if not .status.conditions}}{{.metadata.name}} {{end}}{{end}}' 2>/dev/null)
            [ -n "\$pending" ] && oc adm certificate approve \$pending >/dev/null 2>&1 || true
            sleep 20
          done
        resources:
          requests: { cpu: 20m, memory: 64Mi }
          limits:   { memory: 128Mi }
CSR

  oc -n "$CA_NS" rollout status deploy/cluster-autoscaler --timeout=180s 2>/dev/null \
    || echo "    cluster-autoscaler still starting — check: oc -n $CA_NS get pods"
  oc -n "$CA_NS" rollout status deploy/csr-approver --timeout=120s 2>/dev/null || true

  log "Cluster Autoscaler installed"
  cat <<EOF
    pool 'autoscaled': $pooltype in $loc, scales $pmin..$pmax nodes on Pending-pod pressure.
    It creates Hetzner servers via the API; they boot worker.ign and join (CSRs
    auto-approved). Watch it:
      oc -n $CA_NS logs deploy/cluster-autoscaler -f
      oc -n $CA_NS get configmap cluster-autoscaler-status -o yaml
      oc get nodes -w
    Tune the pool by editing the --nodes flag on deploy/cluster-autoscaler.
    Caveats (platform "none", EXPERIMENTAL): only the '${DOMAIN}-base' firewall is
    attached (HCLOUD_FIREWALL takes one); autoscaled nodes join with their
    Hetzner name, not workerNN; terraform does not manage these nodes.
EOF
  return 0
}

# ── smoke test ────────────────────────────────────────────────────────────
# Prove the Hetzner-API scale-up end to end: create a throwaway workload whose
# pods can't fit on the current (loaded) nodes but DO fit on a fresh pool node,
# so the cluster-autoscaler provisions one via the Hetzner API; watch it join
# (Compute -> Nodes), then delete the workload so it scales back down.
ca_smoke_test() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  oc whoami >/dev/null 2>&1 || { echo "    cannot reach the cluster — is it running?"; return 1; }
  oc -n "$CA_NS" get deploy cluster-autoscaler >/dev/null 2>&1 \
    || { err "cluster-autoscaler is not installed — run --cluster-autoscaler first"; return 1; }

  local ns=ca-smoke-test pooltype camax alloc req nodes baseline replicas
  pooltype=$(oc -n "$CA_NS" get deploy cluster-autoscaler -o jsonpath='{.spec.template.spec.containers[0].command}' 2>/dev/null \
    | grep -oE '\-\-nodes=[0-9]+:[0-9]+:[^:"]+' | head -1 | cut -d: -f3)
  camax=$(oc -n "$CA_NS" get deploy cluster-autoscaler -o jsonpath='{.spec.template.spec.containers[0].command}' 2>/dev/null \
    | grep -oE '\-\-nodes=[0-9]+:[0-9]+' | head -1 | cut -d: -f2)
  # CPU request per pod ~60% of a node so the scheduler fits ~one per node;
  # with replicas = (schedulable nodes)+2, two pods stay Pending -> scale up.
  alloc=$(oc get nodes -l '!node-role.kubernetes.io/master' -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)
  case "$alloc" in *m) alloc=${alloc%m};; "") alloc=8000;; *) alloc=$((alloc*1000));; esac
  req=$(( alloc * 60 / 100 )); [ "$req" -lt 500 ] && req=500
  baseline=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  local baseline_ready; baseline_ready=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  replicas=$(( baseline + 2 ))

  log "Cluster Autoscaler smoke test (pool type ${pooltype:-?}, max ${camax:-?})"
  echo "    baseline nodes: $baseline"
  echo "    creating Deployment ca-smoke: $replicas x pod requesting ${req}m CPU"
  echo "    (fills current nodes; the surplus stays Pending and fits a fresh"
  echo "     ${pooltype:-pool} node, so the autoscaler calls the Hetzner API)"

  oc create ns "$ns" >/dev/null 2>&1 || true
  oc apply -f - >/dev/null <<SMOKE
apiVersion: apps/v1
kind: Deployment
metadata: { name: ca-smoke, namespace: ${ns} }
spec:
  replicas: ${replicas}
  selector: { matchLabels: { app: ca-smoke } }
  template:
    metadata: { labels: { app: ca-smoke } }
    spec:
      terminationGracePeriodSeconds: 0
      containers:
      - name: hog
        image: registry.k8s.io/pause:3.9
        resources:
          requests: { cpu: "${req}m", memory: "64Mi" }
SMOKE

  echo "    pending pods now:"
  oc -n "$ns" get pods --no-headers 2>/dev/null | awk '$3!="Running"' | head
  echo "    waiting for the autoscaler to provision a node AND for it to reach"
  echo "    Ready (Hetzner create + FCOS boot + join + CSR approval, ~3-6 min)…"
  # approve CSRs in-loop too (the csr-approver also does this) and wait until a
  # NEW node is Ready (autoscaled nodes join under their Hetzner rDNS hostname,
  # not 'autoscaled-*', so we compare the Ready COUNT, not names)
  local t=0 ready
  while [ "$t" -lt 90 ]; do       # up to ~15 min
    oc get csr -o go-template='{{range .items}}{{if not .status.conditions}}{{.metadata.name}} {{end}}{{end}}' 2>/dev/null \
      | xargs -r oc adm certificate approve >/dev/null 2>&1 || true
    ready=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
    if [ "${ready:-0}" -gt "$baseline_ready" ]; then echo "    >> Ready nodes: $baseline_ready -> $ready (new node joined)"; break; fi
    sleep 10; t=$((t+1))
  done

  echo; echo "=== nodes (new ones are 'static.*' rDNS names) ==="; oc get nodes 2>/dev/null
  echo "=== autoscaled Hetzner servers ==="
  curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" "https://api.hetzner.cloud/v1/servers?per_page=100" \
    | jq -r '.servers[]|select(.name|startswith("autoscaled"))|"\(.name): \(.server_type.name) \(.status)"' 2>/dev/null
  echo "=== a smoke pod now scheduled on a new node? ==="
  oc -n "$ns" get pods -o wide --no-headers 2>/dev/null | awk '$3=="Running"{print $1, $7}' | grep -vE 'master0|worker0' | head
  echo "=== autoscaler scale-up log ==="
  oc -n "$CA_NS" logs deploy/cluster-autoscaler --tail=300 2>/dev/null \
    | grep -iE 'scale.?up|increasing size|setting.*size|final scale-up' | tail -6

  echo
  echo "    cleaning up the test workload"
  oc delete ns "$ns" --wait=false >/dev/null 2>&1 || true
  cat <<EON
    The added node is now idle and will be removed automatically by the
    autoscaler after its cooldown (--scale-down-delay-after-add 10m, then
    --scale-down-unneeded-time 10m). Watch:  oc get nodes -w
EON
  return 0
}
