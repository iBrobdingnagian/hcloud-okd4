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

  DEVOPS_NOTE="$DEVOPS_NOTE
  harbor      : https://$host  (admin / $pass; OIDC SSO via OpenShift if Dex came up)"
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
    echo "  3) Jenkins      — CI (bundled image, OpenShift OAuth login)"
    echo "  4) GitLab       — SCM/CI (gitlab-operator; heavy, needs a storageclass)"
    echo "  5) Harbor       — container registry (Helm; OpenShift OIDC SSO via Dex)"
    echo "  6) JFrog        — Artifactory OSS (Helm; local admin, no registry/SSO)"
    echo "  7) AWX          — Ansible Automation Platform (Helm awx-operator)"
    echo "  8) All"
    printf 'Selection [1 2 3]: '
    read -r DSEL; DSEL=${DSEL:-1 2 3}
    for n in $DSEL; do
      case "$n" in
        1) selected="$selected cert-manager" ;;
        2) selected="$selected argocd" ;;
        3) selected="$selected jenkins" ;;
        4) selected="$selected gitlab" ;;
        5) selected="$selected harbor" ;;
        6) selected="$selected artifactory" ;;
        7) selected="$selected awx" ;;
        8) selected="cert-manager argocd jenkins gitlab harbor artifactory awx" ;;
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
      harbor)  install_harbor  || true ;;
      artifactory|jfrog) install_artifactory || true ;;
      awx)     install_awx     || true ;;
      *) echo "    unknown component: $want (use cert-manager, argocd, jenkins, gitlab, harbor, artifactory, awx)" ;;
    esac
  done
  [ -n "$DEVOPS_NOTE" ] && log "DevOps tooling:$DEVOPS_NOTE"
  return 0
}
