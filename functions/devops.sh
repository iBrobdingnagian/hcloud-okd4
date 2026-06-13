#!/usr/bin/env bash
# functions/devops.sh — optional DevOps stack (ArgoCD, Jenkins, GitLab)
# Sourced by deploy-okd.sh; not meant to be executed directly.
#
# Installs CI/CD & GitOps tooling on a running cluster. Where an OperatorHub
# operator exists in the cluster's catalog it is used (ArgoCD, GitLab);
# Jenkins has no operator in the community catalog here, so the bundled
# `jenkins-ephemeral` template is used (its image speaks OpenShift OAuth, so
# login uses the cluster identity out of the box).
#
# Each installer is failure-isolated (one failing does not abort the others)
# and appends to DEVOPS_NOTE for the final summary.

DEVOPS_NOTE=""
CATALOG_SRC=community-operators        # the only catalog on this cluster
CATALOG_NS=openshift-marketplace

# ── small OLM helpers ─────────────────────────────────────────────────────
_devops_ns() { oc get ns "$1" >/dev/null 2>&1 || oc create namespace "$1" >/dev/null; }

# wait until a CSV in the namespace reaches Succeeded (operator ready). An
# optional name-substring narrows it to one operator when the namespace hosts
# several (e.g. the global openshift-operators).
_wait_csv() {  # _wait_csv <namespace> [timeout_s] [name-substring]
  local ns=$1 timeout=${2:-300} match=${3:-} t=0 got
  echo "    waiting for the operator to install in '$ns'${match:+ ($match)} (up to ${timeout}s)"
  while [ "$t" -lt "$timeout" ]; do
    got=$(oc -n "$ns" get csv -o json 2>/dev/null \
      | jq -r --arg m "$match" '.items[] | select(.metadata.name|contains($m))
                | select(.status.phase=="Succeeded") | .metadata.name' | head -1)
    [ -n "$got" ] && { echo "    operator ready: $got"; return 0; }
    sleep 10; t=$((t+10))
  done
  echo "    WARNING: no CSV reached 'Succeeded' in '$ns'${match:+ matching '$match'} within ${timeout}s — check: oc -n $ns get csv,sub,ip"
  return 1
}

# ── version policy ────────────────────────────────────────────────────────
# Policy: install operators two releases behind the channel head (N-2) for
# stability, not the bleeding edge. Set VERSION_POLICY=latest to opt out.
VERSION_POLICY=${VERSION_POLICY:-n-2}

# echo the CSV to pin for a package/channel per VERSION_POLICY. PackageManifest
# channel .entries are newest-first, so N-2 is index 2 (fall back to the oldest
# entry if the channel has fewer than 3). Empty result => no pin (use head).
_policy_csv() {  # _policy_csv <package> <channel>
  [ "$VERSION_POLICY" = "n-2" ] || return 0
  oc get packagemanifest "$1" -n "$CATALOG_NS" -o json 2>/dev/null | jq -r --arg c "$2" '
    (.status.channels[] | select(.name==$c) | .entries) as $e
    | if ($e|type)=="array" and ($e|length)>0 then ($e[2].name // $e[-1].name) else empty end'
}

# approve the (Manual) install plan that installs a given CSV
_approve_installplan() {  # _approve_installplan <namespace> <csv>
  local ns=$1 csv=$2 t=0 ip
  # already installed (CSV present)? nothing to approve
  oc -n "$ns" get csv "$csv" >/dev/null 2>&1 && { echo "    $csv already installed"; return 0; }
  while [ "$t" -lt 24 ]; do   # ~2 min: a fresh install plan appears within seconds
    ip=$(oc -n "$ns" get installplan -o json 2>/dev/null | jq -r --arg c "$csv" \
      '.items[] | select(.spec.approved==false) | select(.spec.clusterServiceVersionNames[]?==$c) | .metadata.name' | head -1)
    [ -n "$ip" ] && { oc -n "$ns" patch installplan "$ip" --type=merge -p '{"spec":{"approved":true}}' >/dev/null; \
                      echo "    approved install plan $ip ($csv)"; return 0; }
    sleep 5; t=$((t+1))
  done
  echo "    no install plan for $csv in $ns (operator likely already installed at another version — OLM won't downgrade in place)"; return 1
}

# create a Subscription, pinned to N-2 when the policy applies. A pinned CSV
# forces installPlanApproval=Manual so OLM stays on it (no silent auto-upgrade
# past N-2); the first install plan is then approved automatically here.
_subscribe() {  # _subscribe <namespace> <sub-name> <package> <channel>
  local ns=$1 name=$2 pkg=$3 chan=$4 scsv approval=Automatic inst
  # already installed? OLM can't downgrade in place, so don't re-pin / wait —
  # keep whatever is running (idempotent re-runs short-circuit here)
  inst=$(oc -n "$ns" get subscription "$name" -o jsonpath='{.status.installedCSV}' 2>/dev/null)
  if [ -n "$inst" ]; then
    echo "    $pkg already installed as $inst — leaving as-is (re-run is idempotent; OLM won't downgrade)"
    return 0
  fi
  scsv=$(_policy_csv "$pkg" "$chan")
  [ -n "$scsv" ] && approval=Manual
  echo "    subscribing $pkg ($chan)${scsv:+ pinned to $scsv [policy $VERSION_POLICY]}"
  oc apply -f - >/dev/null <<SUB
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  channel: ${chan}
  name: ${pkg}
  source: ${CATALOG_SRC}
  sourceNamespace: ${CATALOG_NS}
  installPlanApproval: ${approval}
${scsv:+  startingCSV: ${scsv}}
SUB
  [ -n "$scsv" ] && _approve_installplan "$ns" "$scsv"
}

# create namespace + own-namespace OperatorGroup + (pinned) Subscription, wait
_olm_subscribe() {  # _olm_subscribe <namespace> <package> <channel>
  local ns=$1 pkg=$2 chan=$3
  _devops_ns "$ns"
  if [ -z "$(oc -n "$ns" get operatorgroup -o name 2>/dev/null)" ]; then
    oc apply -f - >/dev/null <<OG
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${ns}-og
  namespace: ${ns}
spec:
  targetNamespaces:
  - ${ns}
OG
  fi
  _subscribe "$ns" "$pkg" "$pkg" "$chan"
  _wait_csv "$ns"
}

# ── cert-manager (operator) ───────────────────────────────────────────────
install_certmanager() {
  log "Installing cert-manager (operator)"
  # cert-manager's CSV supports ONLY AllNamespaces, so it goes into the global
  # openshift-operators namespace (which already has an all-namespaces
  # OperatorGroup) rather than an own-namespace OperatorGroup.
  _subscribe openshift-operators cert-manager cert-manager stable
  _wait_csv openshift-operators 300 cert-manager || { DEVOPS_NOTE="$DEVOPS_NOTE
  cert-manager: operator install FAILED — check: oc -n openshift-operators get csv,sub"; return 1; }
  local t=0
  until oc get crd clusterissuers.cert-manager.io >/dev/null 2>&1; do
    t=$((t+1)); [ $t -le 30 ] || break; sleep 5
  done
  # a self-signed ClusterIssuer is a useful default; for real certs add a
  # Let's Encrypt ACME ClusterIssuer (needs reachable HTTP-01/DNS-01).
  oc apply -f - >/dev/null <<'ISS'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
ISS
  DEVOPS_NOTE="$DEVOPS_NOTE
  cert-manager: installed (ClusterIssuer 'selfsigned' ready; add a Let's Encrypt
                issuer for publicly-trusted certs)"
  CERT_MANAGER_READY=1
  return 0
}

# ── ArgoCD (operator) ─────────────────────────────────────────────────────
install_argocd() {
  log "Installing ArgoCD (argocd-operator)"
  # argocd-operator does NOT support the OwnNamespace install mode, so it
  # cannot use an own-namespace OperatorGroup (OLM rejects it with
  # "OwnNamespace InstallModeType not supported"). It DOES support
  # AllNamespaces, so install it into the global openshift-operators namespace
  # (which already has an all-namespaces OperatorGroup), exactly like
  # cert-manager. The operator then watches all namespaces and reconciles the
  # ArgoCD CR we create in the dedicated 'argocd' namespace below.
  # Clean up any broken own-namespace OperatorGroup/Subscription from an
  # earlier attempt so it doesn't keep the install wedged.
  oc -n argocd delete subscription argocd-operator --ignore-not-found >/dev/null 2>&1 || true
  oc -n argocd delete operatorgroup argocd-og --ignore-not-found >/dev/null 2>&1 || true
  _subscribe openshift-operators argocd-operator argocd-operator alpha
  _wait_csv openshift-operators 300 argocd-operator || { DEVOPS_NOTE="$DEVOPS_NOTE
  argocd      : operator install FAILED — check: oc -n openshift-operators get csv,sub"; return 1; }
  _devops_ns argocd   # namespace only for the ArgoCD CR / operands
  # wait for the ArgoCD CRD to be registered by the operator
  local t=0
  until oc get crd argocds.argoproj.io >/dev/null 2>&1; do
    t=$((t+1)); [ $t -le 30 ] || { echo "    ArgoCD CRD never appeared"; return 1; }; sleep 5
  done
  oc apply -f - >/dev/null <<ACR
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: argocd
  namespace: argocd
spec:
  server:
    route:
      enabled: true
      tls:
        termination: reencrypt
ACR
  echo "    waiting for the ArgoCD server route & admin secret"
  local host="" pass="" t2=0
  until [ -n "$host" ] && [ -n "$pass" ]; do
    host=$(oc -n argocd get route argocd-server -o jsonpath='{.spec.host}' 2>/dev/null)
    pass=$(oc -n argocd get secret argocd-cluster -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d 2>/dev/null)
    t2=$((t2+1)); [ $t2 -le 60 ] || break; sleep 5
  done
  if [ -n "$host" ]; then
    DEVOPS_NOTE="$DEVOPS_NOTE
  argocd      : https://$host  (user: admin, password: ${pass:-see secret argocd-cluster})"
  else
    DEVOPS_NOTE="$DEVOPS_NOTE
  argocd      : installed but route not ready yet — oc -n argocd get route argocd-server"
  fi
  return 0
}

# ── Jenkins (no operator in the catalog) ──────────────────────────────────
# There is no Jenkins operator in the community catalog, and the bundled
# jenkins-ephemeral template ships a DeploymentConfig — deprecated in 4.16 and
# unreliable here (its ImageChange trigger doesn't fire, so no pod is ever
# created). We instead run the OpenShift Jenkins *image* directly as a plain
# Deployment, wiring the SA as an OAuth client so login still uses the cluster
# identity (the image's openshift-login plugin + OPENSHIFT_ENABLE_OAUTH).
install_jenkins() {
  log "Installing Jenkins (OpenShift Jenkins image as a Deployment; OpenShift OAuth login)"
  _devops_ns jenkins
  # drop any half-created DeploymentConfig from an earlier template attempt
  oc -n jenkins delete dc jenkins --ignore-not-found >/dev/null 2>&1 || true
  local img
  img=$(oc -n openshift get istag jenkins:2 -o jsonpath='{.image.dockerImageReference}' 2>/dev/null)
  [ -n "$img" ] || img="quay.io/openshift/origin-jenkins:latest"
  echo "    image: $img"
  # SA registered as an OAuth client for the jenkins route, with edit rights
  # in its namespace (Jenkins creates agent pods)
  oc apply -f - >/dev/null <<JKSA
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: jenkins
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.jenkins: '{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"jenkins"}}'
JKSA
  oc adm policy add-role-to-user edit -z jenkins -n jenkins >/dev/null 2>&1 || true
  oc apply -f - >/dev/null <<JK
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jenkins
  namespace: jenkins
spec:
  replicas: 1
  selector:
    matchLabels: { app: jenkins }
  template:
    metadata:
      labels: { app: jenkins }
    spec:
      serviceAccountName: jenkins
      containers:
      - name: jenkins
        image: $img
        env:
        - { name: OPENSHIFT_ENABLE_OAUTH,           value: "true" }
        - { name: OPENSHIFT_ENABLE_REDIRECT_PROMPT, value: "true" }
        - { name: KUBERNETES_MASTER,                value: "https://kubernetes.default:443" }
        - { name: JENKINS_SERVICE_NAME,             value: "jenkins" }
        - { name: JNLP_SERVICE_NAME,                value: "jenkins-jnlp" }
        ports:
        - { containerPort: 8080, name: ui }
        - { containerPort: 50000, name: agent }
        readinessProbe:
          httpGet: { path: /login, port: 8080 }
          initialDelaySeconds: 30
          timeoutSeconds: 3
          periodSeconds: 10
          failureThreshold: 30
        livenessProbe:
          httpGet: { path: /login, port: 8080 }
          initialDelaySeconds: 120
          timeoutSeconds: 5
          periodSeconds: 30
        resources:
          requests: { cpu: 200m, memory: 1Gi }
          limits:   { memory: 2Gi }
        volumeMounts:
        - { name: data, mountPath: /var/lib/jenkins }
      volumes:
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: jenkins
  namespace: jenkins
  annotations:
    service.alpha.openshift.io/dependencies: '[{"name":"jenkins-jnlp","namespace":"","kind":"Service"}]'
spec:
  selector: { app: jenkins }
  ports:
  - { name: ui, port: 80, targetPort: 8080 }
---
apiVersion: v1
kind: Service
metadata:
  name: jenkins-jnlp
  namespace: jenkins
spec:
  selector: { app: jenkins }
  ports:
  - { name: agent, port: 50000, targetPort: 50000 }
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: jenkins
  namespace: jenkins
spec:
  to: { kind: Service, name: jenkins }
  port: { targetPort: ui }
  tls: { termination: edge, insecureEdgeTerminationPolicy: Redirect }
JK
  oc -n jenkins rollout status deploy/jenkins --timeout=300s 2>/dev/null \
    || echo "    Jenkins still starting — check: oc -n jenkins get pods"
  local host
  host=$(oc -n jenkins get route jenkins -o jsonpath='{.spec.host}' 2>/dev/null)
  DEVOPS_NOTE="$DEVOPS_NOTE
  jenkins     : https://${host:-<pending>}  (log in with your OpenShift account)"
  return 0
}

# ── GitLab (operator) — heavy, best-effort on platform "none" ─────────────
install_gitlab() {
  log "Installing GitLab (gitlab-operator-kubernetes) — EXPERIMENTAL / resource-heavy"
  echo "    GitLab pulls ~10 components (gitaly, postgres, redis, minio, webservice,"
  echo "    sidekiq, its own nginx-ingress...). Budget a few GB RAM and several minutes."
  # gitaly/postgres/redis need block/file PVs regardless of object storage
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  gitlab      : FAILED — no usable storageclass"; return 1; }
  # cert-manager: prefer the cluster operator if present, else let GitLab's
  # chart skip certmanager (we have none otherwise)
  local cm_install=false
  [ "${CERT_MANAGER_READY:-0}" = 1 ] && cm_install=false   # cluster cert-manager handles issuers; don't let the chart install its own
  _olm_subscribe gitlab-system gitlab-operator-kubernetes stable || { DEVOPS_NOTE="$DEVOPS_NOTE
  gitlab      : operator install FAILED — check: oc -n gitlab-system get csv,sub"; return 1; }
  local t=0
  until oc get crd gitlabs.apps.gitlab.com >/dev/null 2>&1; do
    t=$((t+1)); [ $t -le 30 ] || { echo "    GitLab CRD never appeared"; return 1; }; sleep 5
  done
  # Let the operator choose the bundled chart version (omit spec.chart.version).
  # certmanager is disabled (none on the cluster); GitLab uses its bundled
  # nginx-ingress with self-signed/shared certs under *.apps.<domain>.
  oc apply -f - >/dev/null <<GCR
apiVersion: apps.gitlab.com/v1beta1
kind: GitLab
metadata:
  name: gitlab
  namespace: gitlab-system
spec:
  chart:
    values:
      global:
        hosts:
          domain: $DOMAIN
        ingress:
          configureCertmanager: false
      certmanager:
        install: false
GCR
  echo "    GitLab CR created. The operator now reconciles the full stack (slow)."
  echo "    track it with:  oc -n gitlab-system get gitlab,pods"
  DEVOPS_NOTE="$DEVOPS_NOTE
  gitlab      : installing (async). URL will be https://gitlab.$DOMAIN once all
                pods are Running. Root password: oc -n gitlab-system get secret \\
                gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d"
  return 0
}

# ── menu / dispatcher ─────────────────────────────────────────────────────
install_devops() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  [ -f "$KUBECONFIG" ] || { echo "    no kubeconfig at $KUBECONFIG — cannot install DevOps tooling"; return 1; }
  oc whoami >/dev/null 2>&1 || { echo "    cannot reach the cluster — is it running?"; return 1; }

  local selected="" want
  if [ -n "$FLAG_DEVOPS_COMPONENTS" ]; then
    selected=$(echo "$FLAG_DEVOPS_COMPONENTS" | tr ',' ' ')
  elif [ "$ASSUME_YES" = 1 ]; then
    selected="cert-manager argocd jenkins"   # safe defaults; gitlab is heavy/opt-in
  else
    echo
    echo "DevOps tooling to install (space-separated numbers, e.g. '1 2 3'):"
    echo "  1) cert-manager — certificate automation (operator)"
    echo "  2) ArgoCD       — GitOps (argocd-operator)"
    echo "  3) Jenkins      — CI (bundled template, OpenShift OAuth login)"
    echo "  4) GitLab       — SCM/CI (gitlab-operator; heavy, needs a storageclass)"
    echo "  5) All"
    printf 'Selection [1 2 3]: '
    read -r DSEL; DSEL=${DSEL:-1 2 3}
    for n in $DSEL; do
      case "$n" in
        1) selected="$selected cert-manager" ;;
        2) selected="$selected argocd" ;;
        3) selected="$selected jenkins" ;;
        4) selected="$selected gitlab" ;;
        5) selected="cert-manager argocd jenkins gitlab" ;;
      esac
    done
  fi
  selected=$(echo "$selected" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ')
  [ -n "$(echo "$selected" | tr -d ' ')" ] || { echo "    nothing selected"; return 0; }
  log "DevOps install: ${selected}"

  # cert-manager first so GitLab can use it; sort -u already orders it ahead of
  # gitlab, but force it explicitly to be safe.
  case " $selected " in *" cert-manager "*) install_certmanager || true ;; esac
  for want in $selected; do
    case "$want" in
      cert-manager) ;;  # already done above
      argocd)  install_argocd  || true ;;
      jenkins) install_jenkins || true ;;
      gitlab)  install_gitlab  || true ;;
      *) echo "    unknown component: $want (use cert-manager, argocd, jenkins, gitlab)" ;;
    esac
  done
  [ -n "$DEVOPS_NOTE" ] && log "DevOps tooling:$DEVOPS_NOTE"
  return 0
}
