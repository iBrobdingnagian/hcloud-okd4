#!/usr/bin/env bash
# functions/devops.sh — optional DevOps stack
#   operators (OLM): cert-manager, ArgoCD, GitLab
#   Helm:            Harbor (+ Dex OIDC bridge), JFrog Artifactory OSS, AWX
#   image/Deployment: Jenkins (OpenShift Jenkins image, OAuth login)
# Sourced by deploy-okd.sh; not meant to be executed directly.
#
# Installs CI/CD, GitOps, registry & cert tooling on a running cluster. Where an
# OperatorHub operator exists in the cluster's catalog it is used (cert-manager,
# ArgoCD, GitLab). Harbor and JFrog have no usable operator in the community
# catalog, so they are installed with Helm. Jenkins runs the OpenShift Jenkins
# image directly (its openshift-login plugin speaks OpenShift OAuth, so login
# uses the cluster identity out of the box).
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

# ── cluster facts & Helm helpers (Harbor / JFrog) ─────────────────────────
# name of the default storageclass (set up by ensure_storage_backend)
_default_sc() {
  oc get storageclass -o json 2>/dev/null | jq -r '.items[]
    | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")
    | .metadata.name' | head -1
}
# the cluster's ingress wildcard domain, e.g. apps.okd4.example.com
_ingress_domain() { oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null; }
# the kube/OAuth API URL, e.g. https://api.okd4.example.com:6443
_api_url() { oc whoami --show-server 2>/dev/null; }

# echo the N-2 chart version for a helm repo/chart per VERSION_POLICY (empty =>
# use the chart head). Extends the operator N-2 policy to Helm-installed apps.
_helm_n2_version() {  # _helm_n2_version <repo/chart>
  [ "$VERSION_POLICY" = "n-2" ] || return 0
  helm search repo "$1" --versions -o json 2>/dev/null \
    | jq -r 'if (type=="array" and length>0) then (.[2].version // .[-1].version) else empty end'
}

# create/replace an edge-terminated Route to a Service in a namespace
_make_route() {  # _make_route <ns> <name> <service> <targetPort> <host>
  oc apply -f - >/dev/null <<RT
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $2
  namespace: $1
spec:
  host: $5
  to: { kind: Service, name: $3 }
  port: { targetPort: $4 }
  tls: { termination: edge, insecureEdgeTerminationPolicy: Redirect }
RT
}

# _reencrypt_route <ns> <name> <service> <targetPort> <host> — for backends that
# serve TLS themselves (e.g. Kiali on 20001). An edge route sends plaintext and the
# backend answers 400; reencrypt makes the router speak HTTPS to the pod.
_reencrypt_route() {
  oc apply -f - >/dev/null <<RT
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $2
  namespace: $1
spec:
  host: $5
  to: { kind: Service, name: $3 }
  port: { targetPort: $4 }
  tls: { termination: reencrypt, insecureEdgeTerminationPolicy: Redirect }
RT
}

# Enable OpenShift User Workload Monitoring — Kiali/mesh metrics land in UWM's
# Prometheus (scraped via ServiceMonitor/PodMonitor). Idempotent; preserves any
# existing cluster-monitoring-config.
_ensure_uwm() {
  local cfg; cfg=$(oc -n openshift-monitoring get cm cluster-monitoring-config \
    -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
  printf '%s' "$cfg" | grep -q 'enableUserWorkload:[[:space:]]*true' && return 0
  if [ -z "$cfg" ]; then cfg="enableUserWorkload: true"; else cfg="enableUserWorkload: true
$cfg"; fi
  oc -n openshift-monitoring create cm cluster-monitoring-config \
    --from-literal=config.yaml="$cfg" --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
}

# _mesh_metrics <ns> — scrape the Envoy sidecars in <ns> into UWM so Kiali sees
# istio_requests_total. Quoted heredoc keeps the relabel regex literal; the ns is
# applied via `oc -n`.
_mesh_metrics() {
  _ensure_uwm
  oc -n "$1" apply -f - >/dev/null 2>&1 <<'PM'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: istio-proxies-monitor
spec:
  selector:
    matchExpressions:
    - {key: istio-prometheus-ignore, operator: DoesNotExist}
  podMetricsEndpoints:
  - path: /stats/prometheus
    interval: 30s
    relabelings:
    - {action: keep, sourceLabels: [__meta_kubernetes_pod_container_name], regex: "istio-proxy"}
    - {action: keep, sourceLabels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape], regex: "true"}
    - action: replace
      regex: (\d+);((([0-9]+?)(\.|$)){4})
      replacement: '$2:$1'
      sourceLabels: [__meta_kubernetes_pod_annotation_prometheus_io_port, __meta_kubernetes_pod_ip]
      targetLabel: __address__
PM
}

# guard: Harbor & JFrog are Helm-installed (no usable operator in the catalog)
_need_helm() {
  command -v helm >/dev/null 2>&1 && return 0
  echo "    helm is not installed on this host — Harbor/JFrog need it. Install helm and re-run."
  return 1
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
  # spec.chart.version is REQUIRED: gitlab-operator refuses to reconcile without it
  # ("invalid version format : invalid semantic version") — and it must be one of
  # the chart versions the *installed* operator supports (see the operator's
  # CHART_VERSIONS file for its tag). Default suits the N-2-pinned operator (3.0.x,
  # which supports 9.10.x/9.11.x/10.0.x); override GITLAB_CHART_VERSION if you change
  # VERSION_POLICY or the operator version. certmanager is disabled (none on the
  # cluster); GitLab uses its bundled nginx-ingress with shared certs under *.apps.
  local glchart=${GITLAB_CHART_VERSION:-9.11.5}
  echo "    GitLab chart version: $glchart (override with GITLAB_CHART_VERSION)"
  oc apply -f - >/dev/null <<GCR
apiVersion: apps.gitlab.com/v1beta1
kind: GitLab
metadata:
  name: gitlab
  namespace: gitlab-system
spec:
  chart:
    version: "$glchart"
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

# ── Dex OIDC bridge (so apps get real OIDC against OpenShift OAuth) ────────
# OpenShift's built-in OAuth server is OAuth2, NOT a compliant OIDC provider
# (no /.well-known/openid-configuration), so apps that want *native* OIDC SSO
# (Harbor's web UI + `docker login`) can't point straight at it. Dex bridges
# the gap: its `openshift` connector delegates to the cluster OAuth server while
# Dex itself exposes a proper OIDC discovery endpoint that Harbor consumes.
# Uses in-memory storage (lab-grade: refresh tokens are lost if Dex restarts).
# Idempotent. Exports DEX_ISSUER and DEX_HARBOR_SECRET for the caller.
DEX_ISSUER="" DEX_HARBOR_SECRET=""
install_dex_oidc() {
  local ingd apiurl
  ingd=$(_ingress_domain); apiurl=$(_api_url)
  [ -n "$ingd" ] && [ -n "$apiurl" ] || { echo "    cannot resolve ingress domain / API url — skipping Dex"; return 1; }
  local dex_host="dex-oidc.$ingd" harbor_host="harbor.$ingd"
  DEX_ISSUER="https://$dex_host"
  _devops_ns dex
  # reuse existing client secrets across re-runs so Harbor's stored config stays valid
  local oc_secret hb_secret
  oc_secret=$(oc -n dex get secret dex-secrets -o jsonpath='{.data.openshift-client-secret}' 2>/dev/null | base64 -d 2>/dev/null)
  hb_secret=$(oc -n dex get secret dex-secrets -o jsonpath='{.data.harbor-client-secret}'    2>/dev/null | base64 -d 2>/dev/null)
  [ -n "$oc_secret" ] || oc_secret=$(openssl rand -hex 24)
  [ -n "$hb_secret" ] || hb_secret=$(openssl rand -hex 24)
  DEX_HARBOR_SECRET="$hb_secret"

  # an OpenShift OAuthClient that Dex authenticates as (cluster-scoped)
  oc apply -f - >/dev/null <<OAC
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: dex-sso
secret: $oc_secret
redirectURIs:
- https://$dex_host/callback
grantMethod: prompt
OAC

  # stash the client secrets (so re-runs are stable) + Dex config
  oc -n dex create secret generic dex-secrets \
    --from-literal=openshift-client-secret="$oc_secret" \
    --from-literal=harbor-client-secret="$hb_secret" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null

  oc -n dex create configmap dex-config --dry-run=client -o yaml --from-literal=config.yaml="$(cat <<CFG
issuer: https://$dex_host
storage:
  type: memory
web:
  http: 0.0.0.0:5556
oauth2:
  skipApprovalScreen: true
connectors:
- type: openshift
  id: openshift
  name: OpenShift
  config:
    issuer: $apiurl
    clientID: dex-sso
    clientSecret: $oc_secret
    redirectURI: https://$dex_host/callback
    insecureCA: true
staticClients:
- id: harbor
  name: Harbor
  secret: $hb_secret
  redirectURIs:
  - https://$harbor_host/c/oidc/callback
CFG
)" | oc apply -f - >/dev/null

  oc apply -f - >/dev/null <<DEX
apiVersion: apps/v1
kind: Deployment
metadata: { name: dex, namespace: dex }
spec:
  replicas: 1
  selector: { matchLabels: { app: dex } }
  template:
    metadata: { labels: { app: dex }, annotations: { checksum/config: "$(echo "$oc_secret$hb_secret$dex_host" | md5sum | cut -c1-12)" } }
    spec:
      containers:
      - name: dex
        image: ghcr.io/dexidp/dex:v2.41.1
        command: ["/usr/local/bin/dex", "serve", "/etc/dex/cfg/config.yaml"]
        ports: [{ containerPort: 5556, name: http }]
        volumeMounts: [{ name: config, mountPath: /etc/dex/cfg }]
        resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { memory: 256Mi } }
      volumes:
      - name: config
        configMap: { name: dex-config }
---
apiVersion: v1
kind: Service
metadata: { name: dex, namespace: dex }
spec:
  selector: { app: dex }
  ports: [{ name: http, port: 5556, targetPort: 5556 }]
DEX
  _make_route dex dex dex 5556 "$dex_host"
  oc -n dex rollout restart deploy/dex >/dev/null 2>&1 || true
  oc -n dex rollout status deploy/dex --timeout=180s 2>/dev/null \
    || echo "    Dex still starting — check: oc -n dex get pods"
  echo "    Dex OIDC issuer: $DEX_ISSUER"
  return 0
}

# enable scan-on-push for a Harbor project so every pushed image is automatically
# scanned by Trivy (report-only — no pull/deploy blocking). Idempotent.
_harbor_autoscan() {  # _harbor_autoscan <project> [harbor-host] [admin-pass]
  local proj=$1 host=${2:-} pass=${3:-}
  [ -n "$host" ] || host="harbor.$(_ingress_domain)"
  [ -n "$pass" ] || pass=$(oc -n harbor get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
  [ -n "$pass" ] || return 1
  curl -sk -u "admin:$pass" -X PUT "https://$host/api/v2.0/projects/$proj" \
    -H 'Content-Type: application/json' -d '{"metadata":{"auto_scan":"true"}}' >/dev/null 2>&1
}

# ── Harbor (Helm) — container registry, OpenShift OIDC SSO via Dex ────────
install_harbor() {
  log "Installing Harbor (Helm goharbor/harbor) + Dex OIDC SSO — EXPERIMENTAL"
  _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  harbor      : FAILED — helm not installed"; return 1; }
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  harbor      : FAILED — no usable storageclass"; return 1; }
  local sc ingd host pass ver
  sc=$(_default_sc); ingd=$(_ingress_domain); host="harbor.$ingd"
  [ -n "$ingd" ] || { DEVOPS_NOTE="$DEVOPS_NOTE
  harbor      : FAILED — cannot resolve ingress domain"; return 1; }
  _devops_ns harbor
  # Harbor pins fixed uids/fsGroups (10000, 999 for pg/redis) — anyuid allows
  # those (RunAsAny). anyuid has NO seccompProfiles though, so we also strip the
  # chart's seccompProfile below (keeping the rest of its hardening) instead of
  # falling back to the much broader 'privileged' SCC.
  oc adm policy add-scc-to-group anyuid system:serviceaccounts:harbor >/dev/null 2>&1 || true

  # stand up the OIDC bridge first (best-effort; Harbor still works w/ local admin)
  install_dex_oidc || echo "    Dex bridge unavailable — Harbor will install with a local admin only"

  helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
  helm repo update harbor >/dev/null 2>&1 || true
  ver=$(_helm_n2_version harbor/harbor)
  [ -n "$ver" ] && echo "    pinning chart harbor/harbor to $ver [policy $VERSION_POLICY]"

  # reuse an existing admin password across re-runs
  pass=$(oc -n harbor get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null)
  [ -n "$pass" ] || pass=$(openssl rand -hex 12)

  # expose.type=clusterIP: Harbor makes a ClusterIP svc "harbor:80"; TLS is
  # terminated at the OpenShift edge route, so disable Harbor-side TLS.
  helm upgrade --install harbor harbor/harbor -n harbor ${ver:+--version "$ver"} \
    --set expose.type=clusterIP \
    --set expose.tls.enabled=false \
    --set externalURL="https://$host" \
    --set harborAdminPassword="$pass" \
    --set-json 'containerSecurityContext={"privileged":false,"allowPrivilegeEscalation":false,"runAsNonRoot":true,"capabilities":{"drop":["ALL"]},"seccompProfile":null}' \
    --set persistence.persistentVolumeClaim.registry.storageClass="$sc" \
    --set persistence.persistentVolumeClaim.registry.size=20Gi \
    --set persistence.persistentVolumeClaim.jobservice.jobLog.storageClass="$sc" \
    --set persistence.persistentVolumeClaim.database.storageClass="$sc" \
    --set persistence.persistentVolumeClaim.redis.storageClass="$sc" \
    --set persistence.persistentVolumeClaim.trivy.storageClass="$sc" \
    --wait --timeout 8m >/dev/null 2>&1 \
    || echo "    helm reported a timeout/error — Harbor may still be settling; check: oc -n harbor get pods"

  # route by the service's *named* port ('http'): the OpenShift router resolves
  # a numeric targetPort against the pod port (8080), not the service port (80),
  # so the name is the unambiguous choice (numeric 80 yields a router 503).
  _make_route harbor harbor harbor http "$host"

  # configure native OIDC against Dex (best-effort; needs Harbor core ready)
  if [ -n "$DEX_ISSUER" ]; then
    echo "    configuring Harbor auth_mode=oidc against $DEX_ISSUER"
    local t=0 code
    while [ "$t" -lt 36 ]; do   # ~3 min for core to answer
      code=$(curl -sk -o /dev/null -w '%{http_code}' -u "admin:$pass" \
        "https://$host/api/v2.0/systeminfo" 2>/dev/null)
      [ "$code" = 200 ] && break
      sleep 5; t=$((t+1))
    done
    if [ "$code" = 200 ]; then
      curl -sk -u "admin:$pass" -X PUT "https://$host/api/v2.0/configurations" \
        -H 'Content-Type: application/json' -d "$(cat <<JSON
{"auth_mode":"oidc_auth","oidc_name":"openshift","oidc_endpoint":"$DEX_ISSUER",
 "oidc_client_id":"harbor","oidc_client_secret":"$DEX_HARBOR_SECRET",
 "oidc_scope":"openid,profile,email,offline_access","oidc_verify_cert":false,
 "oidc_auto_onboard":true,"oidc_user_claim":"email"}
JSON
)" >/dev/null 2>&1 && echo "    Harbor OIDC SSO enabled (login via 'LOGIN VIA OIDC PROVIDER')" \
        || echo "    OIDC config call failed — set it later in Harbor > Configuration > Authentication"
    else
      echo "    Harbor core not reachable yet — enable OIDC later in the UI (endpoint $DEX_ISSUER)"
    fi
  fi

  # auto-scan every image pushed to the default 'library' project (Trivy, report-only)
  _harbor_autoscan library "$host" "$pass" \
    && echo "    scan-on-push (Trivy) enabled for project 'library'"

  DEVOPS_NOTE="$DEVOPS_NOTE
  harbor      : https://$host  (admin / $pass; OIDC SSO via OpenShift if Dex came up)
                scan-on-push enabled (Trivy auto-scans images; see Projects -> appsim/library -> Scanner)"
  return 0
}

# ── JFrog Artifactory OSS (Helm) ──────────────────────────────────────────
# NOTE: OSS edition has NO Docker/OCI registry and NO SSO (both are Pro
# features) — it serves Maven/npm/PyPI/etc. with a local admin only.
install_artifactory() {
  log "Installing JFrog Artifactory OSS (Helm jfrog/artifactory-oss) — EXPERIMENTAL"
  echo "    note: OSS = no Docker registry, no SSO (local admin only; those are Pro features)"
  _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  artifactory : FAILED — helm not installed"; return 1; }
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  artifactory : FAILED — no usable storageclass"; return 1; }
  local sc ingd host ver svc
  sc=$(_default_sc); ingd=$(_ingress_domain); host="artifactory.$ingd"
  [ -n "$ingd" ] || { DEVOPS_NOTE="$DEVOPS_NOTE
  artifactory : FAILED — cannot resolve ingress domain"; return 1; }
  _devops_ns artifactory
  # the artifactory-oss chart pins uid/fsGroup 1030 AND sets seccompProfile on
  # all 9 containers, with no values toggle to disable either — so anyuid (no
  # seccomp) can't admit it. Grant the broader 'privileged' SCC to the ns SAs.
  oc adm policy add-scc-to-group privileged system:serviceaccounts:artifactory >/dev/null 2>&1 || true

  helm repo add jfrog https://charts.jfrog.io >/dev/null 2>&1 || true
  helm repo update jfrog >/dev/null 2>&1 || true
  ver=$(_helm_n2_version jfrog/artifactory-oss)
  [ -n "$ver" ] && echo "    pinning chart jfrog/artifactory-oss to $ver [policy $VERSION_POLICY]"

  # bundled nginx disabled — we expose the JFrog router (8082) via an edge route
  helm upgrade --install artifactory jfrog/artifactory-oss -n artifactory ${ver:+--version "$ver"} \
    --set artifactory.persistence.storageClassName="$sc" \
    --set artifactory.persistence.size=20Gi \
    --set postgresql.persistence.storageClassName="$sc" \
    --set nginx.enabled=false \
    --set artifactory.service.type=ClusterIP \
    --wait --timeout 8m >/dev/null 2>&1 \
    || echo "    helm reported a timeout/error — Artifactory may still be settling; check: oc -n artifactory get pods"

  # the JFrog router service exposes 8082 (UI/API); find it whatever its name is,
  # and route by the port's NAME (router resolves numeric targetPort against the
  # pod port, which may differ from 8082 — see the Harbor note above)
  local svcjson pname
  svcjson=$(oc -n artifactory get svc -o json 2>/dev/null)
  svc=$(echo "$svcjson" | jq -r '.items[] | select([.spec.ports[]?.port]|index(8082)) | .metadata.name' | head -1)
  pname=$(echo "$svcjson" | jq -r --arg s "$svc" '.items[] | select(.metadata.name==$s) | .spec.ports[] | select(.port==8082) | (.name // "8082")' | head -1)
  [ -n "$pname" ] || pname=8082
  if [ -n "$svc" ]; then
    _make_route artifactory artifactory "$svc" "$pname" "$host"
    DEVOPS_NOTE="$DEVOPS_NOTE
  artifactory : https://$host  (default login admin/password; change it on first use)"
  else
    DEVOPS_NOTE="$DEVOPS_NOTE
  artifactory : installed but the 8082 service wasn't found — oc -n artifactory get svc"
  fi
  return 0
}

# ── AWX / Ansible Automation Platform (Helm: awx-operator) ────────────────
# The community AWX Operator ships an official Helm chart that can also create
# the AWX instance itself (AWX.enabled=true). On OpenShift we set
# ingress_type=route so the operator publishes an edge Route automatically.
install_awx() {
  log "Installing AWX / Ansible Automation Platform (Helm awx-operator) — EXPERIMENTAL"
  echo "    deploys the AWX operator + an AWX instance (web, task, ee, redis, managed postgres)"
  _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  awx         : FAILED — helm not installed"; return 1; }
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  awx         : FAILED — no usable storageclass"; return 1; }
  local sc ver host="" pass=""
  sc=$(_default_sc)
  _devops_ns awx
  # managed postgres / awx pods — allow their uids
  oc adm policy add-scc-to-group anyuid system:serviceaccounts:awx >/dev/null 2>&1 || true

  helm repo add awx-operator https://ansible-community.github.io/awx-operator-helm/ >/dev/null 2>&1 || true
  helm repo update awx-operator >/dev/null 2>&1 || true
  ver=$(_helm_n2_version awx-operator/awx-operator)
  [ -n "$ver" ] && echo "    pinning chart awx-operator/awx-operator to $ver [policy $VERSION_POLICY]"

  # operator + AWX CR in one release; ingress_type=route -> OpenShift edge route.
  # postgres PVC lands on the default storageclass. No --wait: the operator
  # reconciles AWX asynchronously, and its kube-rbac-proxy sidecar would keep
  # the pod un-Ready (see the image fix below) and stall a --wait pointlessly.
  helm upgrade --install awx-operator awx-operator/awx-operator -n awx ${ver:+--version "$ver"} \
    --set AWX.enabled=true \
    --set AWX.name=awx \
    --set AWX.spec.ingress_type=route \
    --set AWX.spec.postgres_storage_class="$sc" >/dev/null 2>&1 \
    || echo "    helm reported an error — check: oc -n awx get awx,pods"

  # the chart's metrics sidecar pulls gcr.io/kubebuilder/kube-rbac-proxy, which
  # is frequently unpullable; repoint it at the maintained quay.io/brancz mirror
  # so the operator pod goes Ready (the awx-manager container, and thus AWX
  # reconciliation, work regardless — this just unblocks readiness/metrics).
  local t=0
  until oc -n awx get deploy awx-operator-controller-manager >/dev/null 2>&1; do
    t=$((t+1)); [ $t -le 24 ] || break; sleep 5
  done
  oc -n awx set image deploy/awx-operator-controller-manager \
    kube-rbac-proxy=quay.io/brancz/kube-rbac-proxy:v0.15.0 >/dev/null 2>&1 || true

  echo "    AWX reconciles asynchronously (operator builds web/task/postgres). Watching for the route…"
  local t=0
  until [ -n "$host" ]; do
    host=$(oc -n awx get route awx -o jsonpath='{.spec.host}' 2>/dev/null)
    t=$((t+1)); [ $t -le 48 ] || break; sleep 5   # ~4 min for the route
  done
  pass=$(oc -n awx get secret awx-admin-password -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
  if [ -n "$host" ]; then
    DEVOPS_NOTE="$DEVOPS_NOTE
  awx         : https://$host  (admin / ${pass:-oc -n awx get secret awx-admin-password -o jsonpath='{.data.password}' | base64 -d})"
  else
    DEVOPS_NOTE="$DEVOPS_NOTE
  awx         : installing (async) — watch: oc -n awx get awx,pods,route. Admin pw in
                secret awx-admin-password once the instance is up."
  fi
  return 0
}

# ── SonarQube (Helm) — source-code quality / SAST scanning ────────────────
# NOTE: scans SOURCE CODE (bugs, code smells, security hotspots, coverage) — the
# COMPLEMENT to Harbor/Trivy, which scans container images. Heavy: bundled
# PostgreSQL + an Elasticsearch that needs vm.max_map_count=524288 (set by the
# chart's privileged initSysctl container -> the ns SAs get the 'privileged' SCC).
install_sonarqube() {
  log "Installing SonarQube (Helm SonarSource community edition) — EXPERIMENTAL / resource-heavy"
  _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  sonarqube   : FAILED — helm not installed"; return 1; }
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  sonarqube   : FAILED — no usable storageclass"; return 1; }
  local sc ingd host ver pass
  sc=$(_default_sc); ingd=$(_ingress_domain); host="sonarqube.$ingd"
  [ -n "$ingd" ] || { DEVOPS_NOTE="$DEVOPS_NOTE
  sonarqube   : FAILED — cannot resolve ingress domain"; return 1; }
  _devops_ns sonarqube
  # initSysctl (vm.max_map_count) runs privileged; ES/sonar pin uids -> need privileged
  oc adm policy add-scc-to-group privileged system:serviceaccounts:sonarqube >/dev/null 2>&1 || true
  oc adm policy add-scc-to-group anyuid     system:serviceaccounts:sonarqube >/dev/null 2>&1 || true

  helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube >/dev/null 2>&1 || true
  helm repo update sonarqube >/dev/null 2>&1 || true
  ver=$(_helm_n2_version sonarqube/sonarqube)
  [ -n "$ver" ] && echo "    pinning chart sonarqube/sonarqube to $ver [policy $VERSION_POLICY]"

  # reuse the monitoring passcode across re-runs (the chart requires one)
  pass=$(oc -n sonarqube get secret sonarqube-sonarqube-monitoring-passcode -o jsonpath='{.data.SONAR_WEB_SYSTEMPASSCODE}' 2>/dev/null | base64 -d 2>/dev/null)
  [ -n "$pass" ] || pass=$(openssl rand -hex 12)

  helm upgrade --install sonarqube sonarqube/sonarqube -n sonarqube ${ver:+--version "$ver"} \
    --set community.enabled=true \
    --set postgresql.enabled=true \
    --set postgresql.primary.persistence.storageClass="$sc" \
    --set persistence.enabled=true \
    --set persistence.storageClass="$sc" \
    --set persistence.size=10Gi \
    --set service.type=ClusterIP \
    --set monitoringPasscode="$pass" \
    --set initSysctl.enabled=true \
    --wait --timeout 10m >/dev/null 2>&1 \
    || echo "    SonarQube helm reported a timeout/error — it is slow to start (ES); check: oc -n sonarqube get pods"

  # route to the SonarQube web service (port 9000), named port 'http'
  _make_route sonarqube sonarqube sonarqube-sonarqube http "$host"
  DEVOPS_NOTE="$DEVOPS_NOTE
  sonarqube   : https://$host  (default login admin/admin — change it on first login)
                scans SOURCE CODE (SAST); pair with Harbor/Trivy (image CVEs)"
  return 0
}

# ── Kafka + ZooKeeper (plain manifests) ───────────────────────────────────
# No usable Kafka operator ships in the community catalog here, so we run a
# self-contained, ZooKeeper-backed single-broker cluster as two StatefulSets
# (the canonical Confluent cp-zookeeper + cp-kafka pair, free Community
# license). Kafka speaks its own TCP protocol — an HTTP/TLS edge Route can't
# carry it — so it is ClusterIP-only; clients inside the cluster use the
# bootstrap address kafka.kafka.svc.cluster.local:9092. anyuid lets the images
# run as their own uid (they write to /var/lib/{zookeeper,kafka}).
ZOOKEEPER_IMAGE=${ZOOKEEPER_IMAGE:-confluentinc/cp-zookeeper:7.7.1}
KAFKA_IMAGE=${KAFKA_IMAGE:-confluentinc/cp-kafka:7.7.1}
install_kafka() {
  log "Installing Kafka + ZooKeeper (Confluent cp images, single broker, ZooKeeper-backed)"
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  kafka       : FAILED — no usable storageclass"; return 1; }
  local sc
  sc=$(_default_sc)
  _devops_ns kafka
  # cp images run as a fixed (non-root) uid and write to /var/lib — anyuid
  # (RunAsAny) admits them; restricted-v2's random uid can't write those dirs.
  oc adm policy add-scc-to-group anyuid system:serviceaccounts:kafka >/dev/null 2>&1 || true

  echo "    image (zookeeper): $ZOOKEEPER_IMAGE"
  echo "    image (kafka)    : $KAFKA_IMAGE"

  # ── ZooKeeper ────────────────────────────────────────────────────────────
  oc apply -f - >/dev/null <<ZK
apiVersion: v1
kind: Service
metadata:
  name: zookeeper
  namespace: kafka
spec:
  clusterIP: None
  selector: { app: zookeeper }
  ports:
  - { name: client, port: 2181, targetPort: 2181 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: zookeeper
  namespace: kafka
spec:
  serviceName: zookeeper
  replicas: 1
  selector:
    matchLabels: { app: zookeeper }
  template:
    metadata:
      labels: { app: zookeeper }
    spec:
      securityContext: { fsGroup: 1000 }
      containers:
      - name: zookeeper
        image: $ZOOKEEPER_IMAGE
        env:
        - { name: ZOOKEEPER_CLIENT_PORT, value: "2181" }
        - { name: ZOOKEEPER_TICK_TIME,   value: "2000" }
        ports:
        - { containerPort: 2181, name: client }
        readinessProbe:
          tcpSocket: { port: 2181 }
          initialDelaySeconds: 15
          periodSeconds: 10
          failureThreshold: 30
        resources:
          requests: { cpu: 100m, memory: 256Mi }
          limits:   { memory: 1Gi }
        volumeMounts:
        - { name: data, mountPath: /var/lib/zookeeper/data }
        - { name: log,  mountPath: /var/lib/zookeeper/log }
  volumeClaimTemplates:
  - metadata: { name: data }
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: $sc
      resources: { requests: { storage: 5Gi } }
  - metadata: { name: log }
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: $sc
      resources: { requests: { storage: 5Gi } }
ZK
  oc -n kafka rollout status statefulset/zookeeper --timeout=300s 2>/dev/null \
    || echo "    ZooKeeper still starting — check: oc -n kafka get pods"

  # ── Kafka (single broker; replication factors pinned to 1) ────────────────
  oc apply -f - >/dev/null <<KAFKA
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: kafka
spec:
  clusterIP: None
  selector: { app: kafka }
  ports:
  - { name: broker, port: 9092, targetPort: 9092 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: kafka
spec:
  serviceName: kafka
  replicas: 1
  selector:
    matchLabels: { app: kafka }
  template:
    metadata:
      labels: { app: kafka }
    spec:
      securityContext: { fsGroup: 1000 }
      containers:
      - name: kafka
        image: $KAFKA_IMAGE
        env:
        - { name: KAFKA_BROKER_ID,                          value: "1" }
        - { name: KAFKA_ZOOKEEPER_CONNECT,                  value: "zookeeper:2181" }
        - { name: KAFKA_LISTENERS,                          value: "PLAINTEXT://0.0.0.0:9092" }
        - { name: KAFKA_ADVERTISED_LISTENERS,               value: "PLAINTEXT://kafka.kafka.svc.cluster.local:9092" }
        - { name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP,     value: "PLAINTEXT:PLAINTEXT" }
        - { name: KAFKA_INTER_BROKER_LISTENER_NAME,         value: "PLAINTEXT" }
        - { name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR,   value: "1" }
        - { name: KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR, value: "1" }
        - { name: KAFKA_TRANSACTION_STATE_LOG_MIN_ISR,      value: "1" }
        - { name: KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS,   value: "0" }
        - { name: KAFKA_LOG_DIRS,                           value: "/var/lib/kafka/data" }
        ports:
        - { containerPort: 9092, name: broker }
        readinessProbe:
          tcpSocket: { port: 9092 }
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 40
        resources:
          requests: { cpu: 250m, memory: 512Mi }
          limits:   { memory: 2Gi }
        volumeMounts:
        - { name: data, mountPath: /var/lib/kafka/data }
  volumeClaimTemplates:
  - metadata: { name: data }
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: $sc
      resources: { requests: { storage: 10Gi } }
KAFKA
  oc -n kafka rollout status statefulset/kafka --timeout=300s 2>/dev/null \
    || echo "    Kafka still starting — check: oc -n kafka get pods"

  DEVOPS_NOTE="$DEVOPS_NOTE
  kafka       : in-cluster only (no HTTP route — native Kafka protocol).
                bootstrap server: kafka.kafka.svc.cluster.local:9092
                zookeeper:        zookeeper.kafka.svc.cluster.local:2181"
  return 0
}

# ── Kafka (KRaft — modern, ZooKeeper-less) ────────────────────────────────
# The current Kafka architecture (KIP-500): metadata lives in an internal Raft
# quorum, so ZooKeeper is gone. This runs a single combined node (broker +
# controller roles) from the official Apache image in its own 'kafka-kraft'
# namespace, so it can coexist with the classic ZooKeeper-backed install above.
# Like that one it is ClusterIP-only (native protocol, no HTTP route).
KAFKA_KRAFT_IMAGE=${KAFKA_KRAFT_IMAGE:-apache/kafka:3.9.0}
# a fixed, valid (base64-UUID) cluster id keeps first-format deterministic and
# re-runs idempotent (the image only formats an unformatted log dir).
KAFKA_CLUSTER_ID=${KAFKA_CLUSTER_ID:-MkU3OEVCNTcwNTJENDM2Qk}
install_kafka_kraft() {
  log "Installing Kafka (KRaft mode — ZooKeeper-less, single combined node)"
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  kafka-kraft : FAILED — no usable storageclass"; return 1; }
  local sc
  sc=$(_default_sc)
  _devops_ns kafka-kraft
  oc adm policy add-scc-to-group anyuid system:serviceaccounts:kafka-kraft >/dev/null 2>&1 || true

  echo "    image: $KAFKA_KRAFT_IMAGE"
  oc apply -f - >/dev/null <<KRAFT
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: kafka-kraft
spec:
  clusterIP: None
  selector: { app: kafka-kraft }
  ports:
  - { name: broker, port: 9092, targetPort: 9092 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: kafka-kraft
spec:
  serviceName: kafka
  replicas: 1
  selector:
    matchLabels: { app: kafka-kraft }
  template:
    metadata:
      labels: { app: kafka-kraft }
    spec:
      securityContext: { fsGroup: 1000 }
      containers:
      - name: kafka
        image: $KAFKA_KRAFT_IMAGE
        env:
        - { name: CLUSTER_ID,                               value: "$KAFKA_CLUSTER_ID" }
        - { name: KAFKA_NODE_ID,                            value: "1" }
        - { name: KAFKA_PROCESS_ROLES,                      value: "broker,controller" }
        - { name: KAFKA_CONTROLLER_QUORUM_VOTERS,           value: "1@localhost:9093" }
        # CONTROLLER binds to localhost (matching the single-node quorum voter):
        # in KRaft a combined node derives the controller's advertised address
        # from this listener's host, and Kafka rejects a 0.0.0.0 advertised host.
        - { name: KAFKA_LISTENERS,                          value: "PLAINTEXT://0.0.0.0:9092,CONTROLLER://localhost:9093" }
        - { name: KAFKA_ADVERTISED_LISTENERS,               value: "PLAINTEXT://kafka.kafka-kraft.svc.cluster.local:9092" }
        - { name: KAFKA_CONTROLLER_LISTENER_NAMES,          value: "CONTROLLER" }
        - { name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP,     value: "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT" }
        - { name: KAFKA_INTER_BROKER_LISTENER_NAME,         value: "PLAINTEXT" }
        - { name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR,   value: "1" }
        - { name: KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR, value: "1" }
        - { name: KAFKA_TRANSACTION_STATE_LOG_MIN_ISR,      value: "1" }
        - { name: KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS,   value: "0" }
        - { name: KAFKA_LOG_DIRS,                           value: "/var/lib/kafka/data" }
        ports:
        - { containerPort: 9092, name: broker }
        - { containerPort: 9093, name: controller }
        readinessProbe:
          tcpSocket: { port: 9092 }
          initialDelaySeconds: 20
          periodSeconds: 10
          failureThreshold: 40
        resources:
          requests: { cpu: 250m, memory: 512Mi }
          limits:   { memory: 2Gi }
        volumeMounts:
        - { name: data, mountPath: /var/lib/kafka/data }
  volumeClaimTemplates:
  - metadata: { name: data }
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: $sc
      resources: { requests: { storage: 10Gi } }
KRAFT
  oc -n kafka-kraft rollout status statefulset/kafka --timeout=300s 2>/dev/null \
    || echo "    Kafka (KRaft) still starting — check: oc -n kafka-kraft get pods"

  DEVOPS_NOTE="$DEVOPS_NOTE
  kafka-kraft : KRaft mode, no ZooKeeper. in-cluster only (native protocol).
                bootstrap server: kafka.kafka-kraft.svc.cluster.local:9092"
  return 0
}

# a KafkaUser authenticated by mutual TLS (the User Operator mints a client
# certificate into secret 'app-user') and authorized (simple ACLs) to use the
# appsim topic + consumer group. Idempotent — applied by install_strimzi and
# re-applied by install_appsim so the user/cert exist even on a pre-built cluster.
_strimzi_app_user() {
  oc apply -f - >/dev/null <<USER
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: app-user
  namespace: strimzi
  labels:
    strimzi.io/cluster: my-cluster
spec:
  authentication:
    type: tls
  authorization:
    type: simple
    acls:
      - resource: { type: topic, name: appsim-demo, patternType: literal }
        operations: [Create, Describe, Read, Write]
      - resource: { type: group, name: appsim, patternType: literal }
        operations: [Read, Describe]
USER
}

# ── Strimzi Kafka (operator) ──────────────────────────────────────────────
# The production-grade way to run Kafka on Kubernetes: the Strimzi operator
# (in the community catalog) reconciles a Kafka custom resource into the full
# cluster. Modern Strimzi is KRaft-based and uses KafkaNodePools, so we create
# a single dual-role (broker+controller) pool. The listener is mutual-TLS
# authenticated with simple authorization, so clients connect as a real Kafka
# user (app-user) presenting a client certificate the operator issues. Bootstrap
# service the operator publishes: my-cluster-kafka-bootstrap.strimzi.svc:9093.
install_strimzi() {
  log "Installing Strimzi Kafka (strimzi-kafka-operator) + a KRaft Kafka cluster"
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  strimzi     : FAILED — no usable storageclass"; return 1; }
  local sc
  sc=$(_default_sc)
  _olm_subscribe strimzi strimzi-kafka-operator stable || { DEVOPS_NOTE="$DEVOPS_NOTE
  strimzi     : operator install FAILED — check: oc -n strimzi get csv,sub"; return 1; }
  local t=0
  until oc get crd kafkas.kafka.strimzi.io >/dev/null 2>&1; do
    t=$((t+1)); [ $t -le 30 ] || { echo "    Strimzi CRDs never appeared"; return 1; }; sleep 5
  done
  # node-pools + KRaft annotations: replicas/storage live in the KafkaNodePool;
  # all replication factors pinned to 1 for a single-node lab cluster.
  oc apply -f - >/dev/null <<STRIMZI
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: strimzi
  labels:
    strimzi.io/cluster: my-cluster
spec:
  replicas: 1
  roles:
    - controller
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 10Gi
        deleteClaim: false
        class: $sc
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: strimzi
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    listeners:
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls
    authorization:
      type: simple
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
STRIMZI
  echo "    waiting for the Strimzi Kafka cluster to become Ready (operator builds it; a few min)"
  oc -n strimzi wait kafka/my-cluster --for=condition=Ready --timeout=600s 2>/dev/null \
    || echo "    Kafka not Ready yet — check: oc -n strimzi get kafka,kafkanodepool,pods"
  echo "    creating Kafka user 'app-user' (mTLS) and waiting for its client certificate"
  _strimzi_app_user
  oc -n strimzi wait kafkauser/app-user --for=condition=Ready --timeout=300s 2>/dev/null \
    || echo "    KafkaUser app-user not Ready yet — check: oc -n strimzi get kafkauser"
  DEVOPS_NOTE="$DEVOPS_NOTE
  strimzi     : Kafka cluster 'my-cluster' (KRaft, mutual-TLS). in-cluster
                bootstrap: my-cluster-kafka-bootstrap.strimzi.svc:9093
                user: app-user (cert in secret app-user; CA in
                my-cluster-cluster-ca-cert)"
  return 0
}

# ── Application Simulation (Kafka traffic generator) ──────────────────────
# A tiny end-to-end test app: a producer that publishes a timestamped message
# every second to topic 'appsim-demo', and a consumer that reads the stream and
# logs it — so you can watch real traffic flow through whichever Kafka backend
# you picked. Uses the Apache Kafka image's console producer/consumer (the wire
# protocol is backend-agnostic, so the same client works against the classic
# ZooKeeper-backed cluster or Strimzi). Choose the backend interactively, or set
# APPSIM_BACKEND=kafka|strimzi non-interactively; the backend is auto-installed
# if it isn't present yet.
APPSIM_IMAGE=${APPSIM_IMAGE:-apache/kafka:3.9.0}
install_appsim() {
  log "Installing Application Simulation (Kafka producer/consumer traffic generator)"
  local backend=${APPSIM_BACKEND:-}
  if [ -z "$backend" ]; then
    if [ "$ASSUME_YES" = 1 ] || [ -n "$FLAG_DEVOPS_COMPONENTS" ]; then
      backend=kafka   # default backend for non-interactive runs
    else
      echo "    Which Kafka backend should the simulation use?"
      echo "      1) Kafka + ZooKeeper (classic)"
      echo "      2) Strimzi Kafka (operator)"
      printf '    Backend [1]: '
      read -r BSEL; BSEL=${BSEL:-1}
      case "$BSEL" in 2) backend=strimzi ;; *) backend=kafka ;; esac
    fi
  fi

  _devops_ns kafka-appsim
  # the console tools write under /opt/kafka (owned by the image uid) — anyuid
  # lets them run as that uid instead of restricted-v2's random one.
  oc adm policy add-scc-to-group anyuid system:serviceaccounts:kafka-appsim >/dev/null 2>&1 || true

  local BOOTSTRAP tls=0
  case "$backend" in
    strimzi)
      oc get kafka my-cluster -n strimzi >/dev/null 2>&1 || install_strimzi || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim      : FAILED — Strimzi Kafka backend unavailable"; return 1; }
      # make sure the mTLS user + its certificate exist (no-op if already there)
      _strimzi_app_user
      oc -n strimzi wait kafkauser/app-user --for=condition=Ready --timeout=300s 2>/dev/null \
        || echo "    KafkaUser app-user not Ready yet — proceeding (producer/consumer will retry)"
      # the app runs in kafka-appsim; copy the cluster CA + user cert secrets
      # over (secrets can't be mounted across namespaces)
      local s
      for s in my-cluster-cluster-ca-cert app-user; do
        oc -n strimzi get secret "$s" -o json 2>/dev/null \
          | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences,.metadata.managedFields,.status)' \
          | oc -n kafka-appsim apply -f - >/dev/null 2>&1 \
          || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim      : FAILED — could not copy Strimzi secret '$s' into kafka-appsim"; return 1; }
      done
      BOOTSTRAP="my-cluster-kafka-bootstrap.strimzi.svc:9093"; tls=1
      ;;
    *)
      backend=kafka
      oc -n kafka get statefulset kafka >/dev/null 2>&1 || install_kafka || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim      : FAILED — Kafka+ZooKeeper backend unavailable"; return 1; }
      BOOTSTRAP="kafka.kafka.svc.cluster.local:9092"
      ;;
  esac
  echo "    backend: $backend   bootstrap: $BOOTSTRAP$([ "$tls" = 1 ] && echo '   (mutual TLS as user app-user)')"

  # Producer & consumer each wrap their client in a retry loop so they ride out
  # the broker still coming up (and any restart) instead of crash-looping.
  # For Strimzi we mount the user cert + cluster CA (PKCS12) and write a
  # client.properties that selects SSL with mTLS; the classic backend is plain.
  if [ "$tls" = 1 ]; then
    oc apply -f - >/dev/null <<APPSIMTLS
apiVersion: apps/v1
kind: Deployment
metadata:
  name: appsim-producer
  namespace: kafka-appsim
spec:
  replicas: 1
  selector:
    matchLabels: { app: appsim-producer }
  template:
    metadata:
      labels: { app: appsim-producer }
    spec:
      containers:
      - name: producer
        image: $APPSIM_IMAGE
        command: ["/bin/sh","-c"]
        args:
        - |
          printf 'security.protocol=SSL\nssl.truststore.location=/certs/ca/ca.p12\nssl.truststore.password=%s\nssl.truststore.type=PKCS12\nssl.keystore.location=/certs/user/user.p12\nssl.keystore.password=%s\nssl.keystore.type=PKCS12\n' "\$CA_PASS" "\$USER_PASS" > /tmp/client.properties
          while true; do
            { n=0; while true; do n=\$((n+1)); echo "appsim msg \$n at \$(date -u +%FT%TZ)"; sleep 1; done; } | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $BOOTSTRAP --topic appsim-demo --producer.config /tmp/client.properties
            echo "producer exited; retrying in 5s"; sleep 5
          done
        env:
        - { name: CA_PASS,   valueFrom: { secretKeyRef: { name: my-cluster-cluster-ca-cert, key: ca.password } } }
        - { name: USER_PASS, valueFrom: { secretKeyRef: { name: app-user, key: user.password } } }
        volumeMounts:
        - { name: ca,   mountPath: /certs/ca,   readOnly: true }
        - { name: user, mountPath: /certs/user, readOnly: true }
        resources:
          requests: { cpu: 50m, memory: 256Mi }
          limits:   { memory: 512Mi }
      volumes:
      - name: ca
        secret: { secretName: my-cluster-cluster-ca-cert, items: [{ key: ca.p12, path: ca.p12 }] }
      - name: user
        secret: { secretName: app-user, items: [{ key: user.p12, path: user.p12 }] }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: appsim-consumer
  namespace: kafka-appsim
spec:
  replicas: 1
  selector:
    matchLabels: { app: appsim-consumer }
  template:
    metadata:
      labels: { app: appsim-consumer }
    spec:
      containers:
      - name: consumer
        image: $APPSIM_IMAGE
        command: ["/bin/sh","-c"]
        args:
        - |
          printf 'security.protocol=SSL\nssl.truststore.location=/certs/ca/ca.p12\nssl.truststore.password=%s\nssl.truststore.type=PKCS12\nssl.keystore.location=/certs/user/user.p12\nssl.keystore.password=%s\nssl.keystore.type=PKCS12\n' "\$CA_PASS" "\$USER_PASS" > /tmp/client.properties
          while true; do
            /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BOOTSTRAP --topic appsim-demo --group appsim --from-beginning --consumer.config /tmp/client.properties
            echo "consumer exited; retrying in 5s"; sleep 5
          done
        env:
        - { name: CA_PASS,   valueFrom: { secretKeyRef: { name: my-cluster-cluster-ca-cert, key: ca.password } } }
        - { name: USER_PASS, valueFrom: { secretKeyRef: { name: app-user, key: user.password } } }
        volumeMounts:
        - { name: ca,   mountPath: /certs/ca,   readOnly: true }
        - { name: user, mountPath: /certs/user, readOnly: true }
        resources:
          requests: { cpu: 50m, memory: 256Mi }
          limits:   { memory: 512Mi }
      volumes:
      - name: ca
        secret: { secretName: my-cluster-cluster-ca-cert, items: [{ key: ca.p12, path: ca.p12 }] }
      - name: user
        secret: { secretName: app-user, items: [{ key: user.p12, path: user.p12 }] }
APPSIMTLS
  else
    oc apply -f - >/dev/null <<APPSIM
apiVersion: apps/v1
kind: Deployment
metadata:
  name: appsim-producer
  namespace: kafka-appsim
spec:
  replicas: 1
  selector:
    matchLabels: { app: appsim-producer }
  template:
    metadata:
      labels: { app: appsim-producer }
    spec:
      containers:
      - name: producer
        image: $APPSIM_IMAGE
        command: ["/bin/sh","-c"]
        args:
        - |
          while true; do
            { n=0; while true; do n=\$((n+1)); echo "appsim msg \$n at \$(date -u +%FT%TZ)"; sleep 1; done; } | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $BOOTSTRAP --topic appsim-demo
            echo "producer exited; retrying in 5s"; sleep 5
          done
        resources:
          requests: { cpu: 50m, memory: 256Mi }
          limits:   { memory: 512Mi }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: appsim-consumer
  namespace: kafka-appsim
spec:
  replicas: 1
  selector:
    matchLabels: { app: appsim-consumer }
  template:
    metadata:
      labels: { app: appsim-consumer }
    spec:
      containers:
      - name: consumer
        image: $APPSIM_IMAGE
        command: ["/bin/sh","-c"]
        args:
        - |
          while true; do
            /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BOOTSTRAP --topic appsim-demo --group appsim --from-beginning
            echo "consumer exited; retrying in 5s"; sleep 5
          done
        resources:
          requests: { cpu: 50m, memory: 256Mi }
          limits:   { memory: 512Mi }
APPSIM
  fi
  oc -n kafka-appsim rollout status deploy/appsim-consumer --timeout=180s 2>/dev/null \
    || echo "    consumer still starting — check: oc -n kafka-appsim get pods"

  DEVOPS_NOTE="$DEVOPS_NOTE
  appsim      : simulating traffic on topic 'appsim-demo' via $BOOTSTRAP (backend: $backend$([ "$tls" = 1 ] && echo ', mTLS as app-user')).
                watch it flow: oc -n kafka-appsim logs deploy/appsim-consumer -f"
  return 0
}

# ── OpenSearch + Dashboards (Kibana) + Fluent Bit (Helm) — log stack ──────
# A second, heavier log stack alongside Loki (per request). OpenSearch's JVM needs
# vm.max_map_count=524288 (privileged sysctl init); security plugin disabled for a
# lab (no TLS/auth). Fluent Bit ships every pod's logs to OpenSearch.
install_opensearch() {
  log "Installing OpenSearch + Dashboards (Kibana) + Fluent Bit (Helm) — EXPERIMENTAL / heavy"
  _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  opensearch  : FAILED — helm not installed"; return 1; }
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  opensearch  : FAILED — no usable storageclass"; return 1; }
  local sc ingd; sc=$(_default_sc); ingd=$(_ingress_domain); _devops_ns opensearch
  # ES needs the vm.max_map_count sysctl (privileged init) + fixed uids
  oc adm policy add-scc-to-group privileged system:serviceaccounts:opensearch >/dev/null 2>&1 || true
  oc adm policy add-scc-to-group anyuid     system:serviceaccounts:opensearch >/dev/null 2>&1 || true
  helm repo add opensearch https://opensearch-project.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add fluent https://fluent.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update opensearch fluent >/dev/null 2>&1 || true

  # single node, security plugin disabled (lab: no TLS/auth)
  helm upgrade --install opensearch opensearch/opensearch -n opensearch \
    --set singleNode=true --set replicas=1 \
    --set persistence.size=10Gi \
    --set-json 'extraEnvs=[{"name":"discovery.type","value":"single-node"},{"name":"DISABLE_SECURITY_PLUGIN","value":"true"},{"name":"DISABLE_INSTALL_DEMO_CONFIG","value":"true"},{"name":"OPENSEARCH_JAVA_OPTS","value":"-Xms512m -Xmx512m"}]' \
    --set "persistence.storageClass=$sc" \
    --wait --timeout 10m >/dev/null 2>&1 \
    || echo "    OpenSearch helm reported a timeout/error (slow JVM) — check: oc -n opensearch get pods"
  # Dashboards (the Kibana UI), pointed at the cluster, security disabled
  helm upgrade --install opensearch-dashboards opensearch/opensearch-dashboards -n opensearch \
    --set-json 'opensearchHosts=["http://opensearch-cluster-master:9200"]' \
    --set-json 'extraEnvs=[{"name":"DISABLE_SECURITY_DASHBOARDS_PLUGIN","value":"true"}]' \
    --wait --timeout 6m >/dev/null 2>&1 \
    || echo "    OpenSearch Dashboards helm reported an error — check: oc -n opensearch get pods"
  # Fluent Bit: tail pod logs (hostPath) -> OpenSearch index logstash-*
  oc adm policy add-scc-to-group privileged system:serviceaccounts:opensearch >/dev/null 2>&1 || true
  helm upgrade --install fluent-bit fluent/fluent-bit -n opensearch \
    --set-json 'config.outputs="[OUTPUT]\n    Name  opensearch\n    Match kube.*\n    Host  opensearch-cluster-master\n    Port  9200\n    Suppress_Type_Name On\n    Logstash_Format On\n    Retry_Limit False\n    tls   Off"' \
    --wait --timeout 5m >/dev/null 2>&1 \
    || echo "    Fluent Bit helm reported an error — check: oc -n opensearch get pods -l app.kubernetes.io/name=fluent-bit"
  _make_route opensearch kibana opensearch-dashboards http "kibana.$ingd"
  DEVOPS_NOTE="$DEVOPS_NOTE
  opensearch  : https://kibana.$ingd  (OpenSearch Dashboards = Kibana; security disabled)
                Fluent Bit ships all pod logs -> index logstash-* (duplicates Loki)"
  return 0
}

# ── Istio (Helm, OpenShift profile) — service mesh for Kiali ──────────────
# OpenShift needs istio-cni (sidecar init can't get NET_ADMIN under restricted SCC)
# and global.platform=openshift. Heavy; injects an Envoy sidecar into labelled ns.
install_istio() {
  log "Installing Istio (Helm, OpenShift profile) — EXPERIMENTAL / heavy"
  _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  istio       : FAILED — helm not installed"; return 1; }
  _devops_ns istio-system
  helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
  helm repo update istio >/dev/null 2>&1 || true
  # CNI + sidecars need privileged on OpenShift
  oc adm policy add-scc-to-group privileged system:serviceaccounts:istio-system >/dev/null 2>&1 || true
  helm upgrade --install istio-base istio/base -n istio-system --set defaultRevision=default \
    --wait --timeout 5m >/dev/null 2>&1 || echo "    istio-base helm error — check CRDs"
  # tracing: send Envoy spans to Tempo's Zipkin receiver (:9411, what install_jaeger
  # deploys). The legacy defaultConfig.tracing writes the tracer straight into each
  # sidecar's bootstrap and reliably fires — unlike the Telemetry API's OpenTelemetry
  # provider, which istiod 1.30 was observed NOT to attach to the sidecar listeners
  # (no spans). Only wire it when a Tempo Zipkin receiver actually exists (operator
  # TempoStack distributor :9411) so we don't hand sidecars a dead trace endpoint;
  # an explicit MESH_TRACING_ZIPKIN always wins. sampling=100 for the lab.
  local -a trace_args=()
  local zipkin_addr=${MESH_TRACING_ZIPKIN:-}
  if [ -z "$zipkin_addr" ] && oc -n observability get svc tempo-tempo-distributor >/dev/null 2>&1; then
    zipkin_addr=tempo-tempo-distributor.observability.svc:9411
  fi
  if [ -n "$zipkin_addr" ]; then
    echo "    mesh tracing -> $zipkin_addr"
    trace_args=(--set meshConfig.enableTracing=true \
      --set "meshConfig.defaultConfig.tracing.zipkin.address=$zipkin_addr" \
      --set meshConfig.defaultConfig.tracing.sampling=100)
  else
    echo "    no Tempo Zipkin receiver found — install 'jaeger' (operator Tempo) for mesh traces; skipping tracing wiring"
  fi
  helm upgrade --install istiod istio/istiod -n istio-system \
    --set global.platform=openshift \
    --set meshConfig.defaultConfig.holdApplicationUntilProxyStarts=true \
    "${trace_args[@]}" \
    --wait --timeout 6m >/dev/null 2>&1 \
    || echo "    istiod helm reported an error — check: oc -n istio-system get pods"
  # holdApplicationUntilProxyStarts: make app containers wait for the Envoy sidecar
  # so services that call out on startup (Boutique's email/recommendation, etc.)
  # don't fail liveness/readiness probes in the proxy-startup race and crash-loop.
  # istio-cni in its own ns (required on OpenShift)
  _devops_ns istio-cni
  oc adm policy add-scc-to-group privileged system:serviceaccounts:istio-cni >/dev/null 2>&1 || true
  # NB: this chart has no "openshift" profile (that's an istioctl concept) — passing
  # --set profile=openshift aborts with "unknown profile openshift" and the CNI never
  # installs, leaving injected pods stuck in Init (no istio-cni NetworkAttachmentDef).
  # The correct OpenShift setup is global.platform=openshift + the Multus paths +
  # chained=false so istio-cni registers as a standalone NAD.
  helm upgrade --install istio-cni istio/cni -n istio-cni \
    --set global.platform=openshift \
    --set cni.cniConfDir=/etc/cni/multus/net.d \
    --set cni.cniBinDir=/var/lib/cni/bin \
    --set cni.chained=false \
    --wait --timeout 5m >/dev/null 2>&1 \
    || echo "    istio-cni helm reported an error — check: oc -n istio-cni get pods"
  # scrape istiod control-plane metrics into UWM (Kiali reads them for the graph)
  _ensure_uwm
  oc apply -f - >/dev/null 2>&1 <<'SM'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: istiod-monitor
  namespace: istio-system
spec:
  targetLabels: [app]
  selector:
    matchLabels: {istio: pilot}
  endpoints:
  - {port: http-monitoring, interval: 30s}
SM
  DEVOPS_NOTE="$DEVOPS_NOTE
  istio       : installed (istiod + istio-cni + zipkin tracing -> Tempo). Label a
                namespace istio-injection=enabled for Envoy sidecars; pair with Kiali
                to visualize the mesh and install 'jaeger' to see distributed traces"
  return 0
}

# ── Kiali (Helm) — service-mesh console (needs Istio) ─────────────────────
install_kiali() {
  log "Installing Kiali (Helm kiali-server) — EXPERIMENTAL"
  _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  kiali       : FAILED — helm not installed"; return 1; }
  oc -n istio-system get deploy istiod >/dev/null 2>&1 || install_istio || true
  local ingd; ingd=$(_ingress_domain)
  _ensure_uwm   # Kiali reads metrics from UWM's thanos-querier
  helm repo add kiali https://kiali.org/helm-charts >/dev/null 2>&1 || true
  helm repo update kiali >/dev/null 2>&1 || true
  # anonymous auth (lab); wire Prometheus (UWM), tracing (Tempo/Jaeger), Grafana.
  # thanos-querier needs a bearer token (Kiali's SA) + it serves a service-CA cert
  # Kiali doesn't trust — hence prometheus.auth: bearer/use_kiali_token/skip-verify.
  # Without this Kiali logs "x509: certificate signed by unknown authority" and the
  # graph stays empty ("metrics features temporarily unavailable").
  # Only wire the tracing/Grafana external services when those components are
  # actually present, so Kiali doesn't ship dead links (same detect-then-wire
  # discipline as _grafana_add_datasource). Prometheus (UWM) is always available.
  local -a ext_args=(
    --set auth.strategy=anonymous
    --set external_services.prometheus.url=https://thanos-querier.openshift-monitoring.svc:9091
    --set external_services.prometheus.auth.type=bearer
    --set external_services.prometheus.auth.use_kiali_token=true
    --set external_services.prometheus.auth.insecure_skip_verify=true
  )
  # tracing: the operator TempoStack's Jaeger query UI (:16686) — helm single-binary
  # Tempo has no such UI, so only wire when the operator query-frontend svc exists.
  if oc -n observability get svc tempo-tempo-query-frontend >/dev/null 2>&1; then
    ext_args+=(
      --set external_services.tracing.enabled=true
      --set external_services.tracing.use_grpc=false
      --set external_services.tracing.internal_url=http://tempo-tempo-query-frontend.observability.svc:16686
    )
  else
    ext_args+=(--set external_services.tracing.enabled=false)
    echo "    no operator Tempo (Jaeger UI) found — install 'jaeger' to link traces in Kiali"
  fi
  # Grafana link only if the monitoring Grafana is deployed
  if oc -n grafana get svc grafana >/dev/null 2>&1; then
    ext_args+=(
      --set external_services.grafana.enabled=true
      --set external_services.grafana.internal_url=http://grafana.grafana.svc:3000
    )
  else
    ext_args+=(--set external_services.grafana.enabled=false)
    echo "    no monitoring Grafana found — run --monitoring to link Grafana in Kiali"
  fi
  helm upgrade --install kiali-server kiali/kiali-server -n istio-system \
    "${ext_args[@]}" \
    --wait --timeout 5m >/dev/null 2>&1 \
    || echo "    Kiali helm reported an error — check: oc -n istio-system get pods -l app=kiali"
  # let the Kiali SA query thanos-querier (platform + UWM metrics)
  oc adm policy add-cluster-role-to-user cluster-monitoring-view -z kiali -n istio-system >/dev/null 2>&1 || true
  oc -n istio-system rollout restart deploy/kiali >/dev/null 2>&1 || true
  # Kiali serves HTTPS on 20001 (svc port name "tcp"); a reencrypt route (not edge) is
  # required or the router gets a 400 and the UI shows "Application is not available".
  _reencrypt_route istio-system kiali kiali 20001 "kiali.$ingd"
  DEVOPS_NOTE="$DEVOPS_NOTE
  kiali       : https://kiali.$ingd  (mesh console; needs Istio + a sidecar-injected app,
                e.g. the 'appsim-mesh' scenario; tracing -> Tempo/Jaeger, metrics -> UWM.
                Run a mesh scenario like appsim-mesh/appsim-bookinfo/appsim-emojivoto for a live graph)"
  return 0
}

# ── GitLab Runner (Helm) — CI engine alternative to Jenkins ───────────────
# Registers a Kubernetes-executor runner to the in-cluster GitLab so appsim-cicd
# can run on GitLab CI (.gitlab-ci.yml) instead of the Jenkins pipeline.
# _install_gitlab_runner <gitlab-url> <runner-token>
install_gitlab_runner() {
  local gl=$1 token=$2
  log "Installing GitLab Runner (Helm, Kubernetes executor)"
  _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  gitlab-runner: FAILED — helm not installed"; return 1; }
  [ -n "$gl" ] && [ -n "$token" ] || { DEVOPS_NOTE="$DEVOPS_NOTE
  gitlab-runner: FAILED — gitlab URL/runner token not provided"; return 1; }
  _devops_ns gitlab-runner
  oc adm policy add-scc-to-group anyuid     system:serviceaccounts:gitlab-runner >/dev/null 2>&1 || true
  oc adm policy add-scc-to-group privileged system:serviceaccounts:gitlab-runner >/dev/null 2>&1 || true
  helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
  helm repo update gitlab >/dev/null 2>&1 || true
  helm upgrade --install gitlab-runner gitlab/gitlab-runner -n gitlab-runner \
    --set gitlabUrl="$gl" \
    --set runnerToken="$token" \
    --set rbac.create=true \
    --set-json 'runners.config="[[runners]]\n  [runners.kubernetes]\n    namespace = \"gitlab-runner\"\n    image = \"alpine:3.20\"\n    privileged = false"' \
    --wait --timeout 5m >/dev/null 2>&1 \
    || echo "    GitLab Runner helm reported an error — check: oc -n gitlab-runner get pods"
  DEVOPS_NOTE="$DEVOPS_NOTE
  gitlab-runner: registered to $gl (Kubernetes executor) — runs .gitlab-ci.yml pipelines"
  return 0
}

# ── menu / dispatcher ─────────────────────────────────────────────────────
install_devops() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  [ -f "$KUBECONFIG" ] || { echo "    no kubeconfig at $KUBECONFIG — cannot install DevOps tooling"; return 1; }
  oc whoami >/dev/null 2>&1 || { echo "    cannot reach the cluster — is it running?"; return 1; }

  local selected="" want
  : "${DEVOPS_NOTE:=}"
  # Interactive runs loop: after each install round the menu is redrawn so you can
  # keep picking tools without relaunching the script. Pick 0 (Done/Back) to leave.
  while true; do
    selected=""
  if [ -n "$FLAG_DEVOPS_COMPONENTS" ]; then
    selected=$(echo "$FLAG_DEVOPS_COMPONENTS" | tr ',' ' ')
  elif [ "$ASSUME_YES" = 1 ]; then
    selected="cert-manager argocd jenkins"   # safe defaults; gitlab is heavy/opt-in
  else
    echo
    echo "DevOps tooling to install (space-separated numbers, e.g. '1 2 3'; 0 = done/back):"
    echo "  0) Done / Back  — finish DevOps and continue the deployment"
    echo "  1) cert-manager — certificate automation (operator)"
    echo "  2) ArgoCD       — GitOps (argocd-operator)"
    echo "  3) Jenkins      — CI (bundled image, OpenShift OAuth login)"
    echo "  4) GitLab       — SCM/CI (gitlab-operator; heavy, needs a storageclass)"
    echo "  5) Harbor       — container registry (Helm; OpenShift OIDC SSO via Dex)"
    echo "  6) JFrog        — Artifactory OSS (Helm; local admin, no registry/SSO)"
    echo "  7) AWX          — Ansible Automation Platform (Helm awx-operator)"
    echo "  8) Kafka        — Kafka + ZooKeeper (classic, single broker, in-cluster only)"
    echo "  9) Kafka KRaft  — Kafka KRaft mode (modern, ZooKeeper-less, in-cluster only)"
    echo " 10) Strimzi      — Strimzi Kafka operator + a KRaft Kafka cluster"
    echo " 11) App Sim      — Application Simulation: Kafka producer/consumer traffic demo"
    echo " 12) Loki         — logs (Loki + Alloy shipper; Helm single-binary or Operator)"
    echo " 13) Tempo        — traces (Tempo; Helm single-binary or Operator)"
    echo " 14) OTel         — OpenTelemetry Collector (traces->Tempo, metrics->UWM)"
    echo " 15) Observability— Loki + Tempo + OTel together"
    echo "  -- application simulations (real-world scenarios) --"
    echo " 16) Sim:GitOps   — podinfo deployed by ArgoCD (Helm from Git) + traffic"
    echo " 17) Sim:Boutique — Online Boutique: 11 microservices + Locust loadgen [heavy]"
    echo " 18) Sim:Events   — Kafka pipeline producer->streams->consumer (Strimzi clients)"
    echo " 19) Sim:AWX      — Ansible project + job template, launched (automation)"
    echo " 20) Sim:CI/CD    — Jenkins->Harbor->GitLab->ArgoCD GitOps loop [heavy]"
    echo " 21) Sim:All      — GitOps + Events + AWX (light scenario subset)"
    echo " 22) SonarQube    — source-code quality / SAST (Helm; complements Harbor image scans)"
    echo " 23) Jaeger       — Jaeger UI for traces (exposes the Tempo-operator query UI)"
    echo " 24) OpenSearch   — OpenSearch + Dashboards (Kibana) + Fluent Bit logs [heavy]"
    echo " 25) Istio        — service mesh (Helm, OpenShift profile) [heavy]"
    echo " 26) Kiali        — service-mesh console (needs Istio)"
    echo " 27) Sim:Mesh     — Online Boutique inside Istio, observed by Kiali/Jaeger [heavy]"
    echo " 28) Sim:Bookinfo — Istio Bookinfo in the mesh + traffic gen (classic Kiali demo)"
    echo " 29) Sim:Emoji    — emojivoto in the mesh (built-in vote-bot traffic)"
    echo " 30) All          — all DevOps tools (no app simulations)"
    printf 'Selection [1 2 3, or 0 to finish]: '
    read -r DSEL || DSEL=0; DSEL=${DSEL:-1 2 3}   # Ctrl-D / EOF => 0 (done)
    for n in $DSEL; do
      case "$n" in
        0|q|Q|done|back|quit) selected="$selected __back__" ;;
        1) selected="$selected cert-manager" ;;
        2) selected="$selected argocd" ;;
        3) selected="$selected jenkins" ;;
        4) selected="$selected gitlab" ;;
        5) selected="$selected harbor" ;;
        6) selected="$selected artifactory" ;;
        7) selected="$selected awx" ;;
        8) selected="$selected kafka" ;;
        9) selected="$selected kafka-kraft" ;;
        10) selected="$selected strimzi-kafka" ;;
        11) selected="$selected appsim" ;;
        12) selected="$selected loki" ;;
        13) selected="$selected tempo" ;;
        14) selected="$selected otel" ;;
        15) selected="$selected observability" ;;
        16) selected="$selected appsim-gitops" ;;
        17) selected="$selected appsim-boutique" ;;
        18) selected="$selected appsim-events" ;;
        19) selected="$selected appsim-awx" ;;
        20) selected="$selected appsim-cicd" ;;
        21) selected="$selected appsim-all" ;;
        22) selected="$selected sonarqube" ;;
        23) selected="$selected jaeger" ;;
        24) selected="$selected opensearch" ;;
        25) selected="$selected istio" ;;
        26) selected="$selected kiali" ;;
        27) selected="$selected appsim-mesh" ;;
        28) selected="$selected appsim-bookinfo" ;;
        29) selected="$selected appsim-emojivoto" ;;
        30) selected="cert-manager argocd jenkins gitlab harbor artifactory awx sonarqube kafka kafka-kraft strimzi-kafka" ;;
      esac
    done
    # observability components install via Helm (single-binary) or via Operators;
    # ask once and rewrite the selected obs tokens to their -operator variants.
    case " $selected " in
      *" loki "*|*" tempo "*|*" otel "*|*" observability "*)
        printf 'Observability install method — 1) Helm single-binary  2) Operators [1]: '
        read -r OMETHOD; OMETHOD=${OMETHOD:-1}
        if [ "$OMETHOD" = 2 ]; then
          local rebuilt="" s
          for s in $selected; do
            case "$s" in
              loki|tempo|otel|observability) rebuilt="$rebuilt ${s}-operator" ;;
              *) rebuilt="$rebuilt $s" ;;
            esac
          done
          selected=$rebuilt
        fi
        ;;
    esac
  fi
  # 0 / Done / Back from the interactive menu: leave the loop without installing.
  case " $selected " in *" __back__ "*) echo "    DevOps: continuing the deployment"; break ;; esac
  selected=$(echo "$selected" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ')
  if [ -z "$(echo "$selected" | tr -d ' ')" ]; then
    echo "    nothing selected"
    # non-interactive selection was empty: done. Interactive: redraw the menu.
    if [ -n "$FLAG_DEVOPS_COMPONENTS" ] || [ "$ASSUME_YES" = 1 ]; then break; else continue; fi
  fi
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
      harbor)  install_harbor  || true ;;
      artifactory|jfrog) install_artifactory || true ;;
      awx)     install_awx     || true ;;
      sonarqube|sonar) install_sonarqube || true ;;
      jaeger)          install_jaeger     || true ;;
      opensearch|kibana) install_opensearch || true ;;
      istio)           install_istio      || true ;;
      kiali)           install_kiali      || true ;;
      kafka|zookeeper)   install_kafka || true ;;
      kafka-kraft|kraft) install_kafka_kraft || true ;;
      strimzi-kafka|strimzi) install_strimzi || true ;;
      appsim|app-sim|application-simulation) install_appsim || true ;;
      appsim-gitops)   install_appsim_gitops   || true ;;
      appsim-boutique) install_appsim_boutique || true ;;
      appsim-events)   install_appsim_events   || true ;;
      appsim-awx)      install_appsim_awx      || true ;;
      appsim-cicd)     install_appsim_cicd     || true ;;
      appsim-all)      install_appsim_gitops || true; install_appsim_events || true; install_appsim_awx || true ;;
      appsim-mesh)     install_appsim_mesh || true ;;
      appsim-bookinfo) install_appsim_bookinfo  || true ;;
      appsim-emojivoto|appsim-emoji) install_appsim_emojivoto || true ;;
      loki)            install_loki  helm     || true ;;
      loki-operator)   install_loki  operator || true ;;
      tempo)           install_tempo helm     || true ;;
      tempo-operator)  install_tempo operator || true ;;
      otel|otel-operator) ;;  # deferred below so Tempo exists first (OTLP target)
      observability|obs)      install_loki helm || true; install_tempo helm || true; install_otel helm || true ;;
      observability-operator) install_loki operator || true; install_tempo operator || true; install_otel operator || true ;;
      *) echo "    unknown component: $want (use cert-manager, argocd, jenkins, gitlab, harbor, artifactory, awx, sonarqube, jaeger, opensearch, istio, kiali, kafka, kafka-kraft, strimzi-kafka, appsim, loki[-operator], tempo[-operator], otel[-operator], observability[-operator], appsim-gitops, appsim-boutique, appsim-events, appsim-awx, appsim-cicd, appsim-mesh, appsim-bookinfo, appsim-emojivoto, appsim-all)" ;;
    esac
  done
  # OpenTelemetry last: its OTLP exporter targets Tempo, so Tempo must be up
  # first when both are selected à-la-carte (sort -u would otherwise run otel first).
  case " $selected " in
    *" otel-operator "*) install_otel operator || true ;;
    *" otel "*)          install_otel helm     || true ;;
  esac
  [ -n "$DEVOPS_NOTE" ] && log "DevOps tooling:$DEVOPS_NOTE"
  DEVOPS_NOTE=""   # per-round summary — reset before the menu is redrawn
  # non-interactive selections (flags / --yes) run once; the interactive menu loops
  # back so you can install another component without relaunching the script.
  if [ -n "$FLAG_DEVOPS_COMPONENTS" ] || [ "$ASSUME_YES" = 1 ]; then break; fi
  done
  return 0
}
