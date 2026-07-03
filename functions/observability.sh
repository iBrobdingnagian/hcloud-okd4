#!/usr/bin/env bash
# functions/observability.sh — logs (Loki) + traces (Tempo) + OpenTelemetry
# Sourced by deploy-okd.sh; not meant to be executed directly.
#
# This is the LOG + TRACE complement to functions/monitoring.sh (which is
# metrics-only: User-Workload Monitoring Prometheus/Thanos + Grafana). Each
# signal installs two ways:
#
#   <name>            Helm single-binary  — filesystem/PVC, no object storage,
#                                           smallest footprint (lab-friendly).
#   <name>-operator   OLM operator        — LokiStack / TempoStack /
#                                           OpenTelemetryCollector. LokiStack and
#                                           TempoStack REQUIRE S3 object storage,
#                                           so the operator path stands up a small
#                                           in-cluster MinIO (no external bucket).
#
# Everything lands in the 'observability' namespace and, when the Grafana from
# --monitoring is present, is wired in as Loki/Tempo datasources automatically.
#
# Reuses helpers from functions/devops.sh: _devops_ns, _default_sc, _need_helm,
# _helm_n2_version, _subscribe, _wait_csv, ensure_storage_backend, plus the
# DEVOPS_NOTE accumulator and log() (functions/helpers.sh). All installers are
# best-effort (EXPERIMENTAL): they warn and continue rather than abort a deploy.

OBS_NS=${OBS_NS:-observability}
MINIO_ENDPOINT="http://minio.${OBS_NS}.svc:9000"

# namespace + anyuid (Loki/Alloy/MinIO pin fixed uids; Alloy reads host log dirs)
_obs_ns() {
  _devops_ns "$OBS_NS"
  oc adm policy add-scc-to-group anyuid "system:serviceaccounts:$OBS_NS" >/dev/null 2>&1 || true
}

# ── in-cluster S3 (MinIO) for the operator path ───────────────────────────
# LokiStack / TempoStack need an S3-compatible object store; platform "none"
# has none, so deploy a single MinIO on a PVC and create the loki/tempo buckets.
# Idempotent: re-runs reuse the existing creds + deployment. Sets MINIO_ENDPOINT.
_ensure_minio() {
  local sc user pass
  sc=$(_default_sc)
  if oc -n "$OBS_NS" get secret minio-root >/dev/null 2>&1; then
    user=$(oc -n "$OBS_NS" get secret minio-root -o jsonpath='{.data.MINIO_ROOT_USER}'     | base64 -d)
    pass=$(oc -n "$OBS_NS" get secret minio-root -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)
  else
    user=minioadmin; pass=$(openssl rand -hex 16)
    oc -n "$OBS_NS" create secret generic minio-root \
      --from-literal=MINIO_ROOT_USER="$user" \
      --from-literal=MINIO_ROOT_PASSWORD="$pass" >/dev/null
  fi
  echo "    deploying in-cluster MinIO (S3 backend for LokiStack/TempoStack)"
  oc apply -f - >/dev/null <<MINIO
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: minio, namespace: $OBS_NS }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $sc
  resources: { requests: { storage: 20Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: minio, namespace: $OBS_NS }
spec:
  replicas: 1
  selector: { matchLabels: { app: minio } }
  template:
    metadata: { labels: { app: minio } }
    spec:
      securityContext: { fsGroup: 1000 }
      containers:
      - name: minio
        image: quay.io/minio/minio:latest
        args: ["server", "/data", "--console-address", ":9001"]
        envFrom:
        - secretRef: { name: minio-root }
        ports:
        - { containerPort: 9000, name: s3 }
        - { containerPort: 9001, name: console }
        readinessProbe:
          httpGet: { path: /minio/health/ready, port: 9000 }
          initialDelaySeconds: 10
        resources:
          requests: { cpu: 100m, memory: 256Mi }
          limits:   { memory: 1Gi }
        volumeMounts:
        - { name: data, mountPath: /data }
      volumes:
      - name: data
        persistentVolumeClaim: { claimName: minio }
---
apiVersion: v1
kind: Service
metadata: { name: minio, namespace: $OBS_NS }
spec:
  selector: { app: minio }
  ports:
  - { name: s3, port: 9000, targetPort: 9000 }
  - { name: console, port: 9001, targetPort: 9001 }
MINIO
  oc -n "$OBS_NS" rollout status deploy/minio --timeout=180s >/dev/null 2>&1 \
    || echo "    MinIO not ready yet — bucket creation may retry; check: oc -n $OBS_NS get pods"
  # create the loki/tempo buckets with a SYNCHRONOUS one-shot mc pod (a batch
  # Job raced: it ran async and a second _ensure_minio call would delete it
  # mid-run, leaving zero buckets). MC_HOST_m injects the alias via env so mc
  # needs no config file; the loop tolerates a MinIO that is still coming up.
  oc -n "$OBS_NS" delete pod minio-mkbucket --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$OBS_NS" run minio-mkbucket --image=quay.io/minio/mc:latest --restart=Never --rm -i --quiet \
    --env=MC_HOST_m="http://$user:$pass@minio:9000" \
    --command -- /bin/sh -c '
      n=0; while [ $n -lt 40 ]; do mc ls m >/dev/null 2>&1 && break; n=$((n+1)); sleep 3; done
      mc mb -p m/loki && mc mb -p m/tempo && mc ls m' >/dev/null 2>&1 \
    || echo "    bucket creation pod failed — check: oc -n $OBS_NS get pods | grep minio-mkbucket"
}

# create the LokiStack/TempoStack object-storage Secret from the MinIO creds.
# _minio_s3_secret <secret-name> <bucket-key> <bucket-value>
#   loki  wants keys: endpoint,bucketnames,access_key_id,access_key_secret
#   tempo wants keys: endpoint,bucket,     access_key_id,access_key_secret
# NOTE: a 'region' key must be passed ONLY for Loki. The tempo-operator treats
# 'region' as a short-lived (STS) field and rejects a secret that also carries
# static access keys ("contains fields for long lived and short lived config").
_minio_s3_secret() {  # _minio_s3_secret <secret> <bucket-key> <bucket-value> [region]
  local name=$1 bkey=$2 bval=$3 region=${4:-} user pass region_arg=()
  user=$(oc -n "$OBS_NS" get secret minio-root -o jsonpath='{.data.MINIO_ROOT_USER}'     | base64 -d)
  pass=$(oc -n "$OBS_NS" get secret minio-root -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)
  [ -n "$region" ] && region_arg=(--from-literal=region="$region")
  oc -n "$OBS_NS" create secret generic "$name" \
    --from-literal=endpoint="$MINIO_ENDPOINT" \
    --from-literal="$bkey=$bval" \
    --from-literal=access_key_id="$user" \
    --from-literal=access_key_secret="$pass" \
    ${region_arg[@]+"${region_arg[@]}"} \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
}

# ── Grafana datasource wiring (reuse the Grafana from --monitoring) ────────
# _grafana_add_datasource <name> <datasource-yaml>
# Adds the datasource as a <name>.yaml KEY in the grafana-datasources configMap
# that monitoring.sh mounts at /etc/grafana/provisioning/datasources. Grafana
# provisions every *.yaml in that dir, and each configMap key surfaces as a file
# there — so a new key = a new datasource. (We must NOT mount a separate configMap
# via subPath into that dir: it is already a configMap mount, and an overlay
# subPath mount fails container init with 'not a directory'.) Idempotent.
_grafana_add_datasource() {
  local name=$1 yaml=$2
  if ! oc -n grafana get deploy/grafana >/dev/null 2>&1; then
    DEVOPS_NOTE="$DEVOPS_NOTE
  $name (grafana): no Grafana found (run --monitoring) — add the datasource by hand"
    return 0
  fi
  if oc -n grafana get configmap grafana-datasources >/dev/null 2>&1; then
    oc -n grafana get configmap grafana-datasources -o json \
      | jq --arg k "$name.yaml" --arg v "$yaml" '.data[$k]=$v' \
      | oc apply -f - >/dev/null
  else
    oc -n grafana create configmap grafana-datasources \
      --from-literal="$name.yaml=$yaml" --dry-run=client -o yaml | oc apply -f - >/dev/null
  fi
  oc -n grafana rollout restart deploy/grafana >/dev/null 2>&1 || true
}

# datasource provisioning YAML builders (shared by install_* and _obs_grafana_wire)
_loki_ds_plain()   { cat <<DS
apiVersion: 1
datasources:
- name: Loki
  type: loki
  uid: loki
  access: proxy
  url: $1
DS
}
_loki_ds_gateway() { cat <<DS
apiVersion: 1
datasources:
- name: Loki
  type: loki
  uid: loki
  access: proxy
  url: $1
  jsonData:
    tlsSkipVerify: true
    httpHeaderName1: 'Authorization'
  secureJsonData:
    httpHeaderValue1: 'Bearer $2'
DS
}
_tempo_ds()        { cat <<DS
apiVersion: 1
datasources:
- name: Tempo
  type: tempo
  uid: tempo
  access: proxy
  url: $1
DS
}

# Wire whatever Loki/Tempo is deployed in OBS_NS into an EXISTING Grafana. This
# is the reverse-ordering bridge: install_grafana (functions/monitoring.sh)
# calls it so datasources appear even when the observability stack was installed
# BEFORE Grafana (the install_loki/install_tempo path covers the other order).
_obs_grafana_wire() {
  oc -n grafana get deploy/grafana >/dev/null 2>&1 || return 0
  oc get ns "$OBS_NS" >/dev/null 2>&1 || return 0
  : "${DEVOPS_NOTE:=}"
  if oc -n "$OBS_NS" get lokistack logging >/dev/null 2>&1; then        # operator Loki
    local gw="https://logging-gateway-http.$OBS_NS.svc:8080/api/logs/v1/application" token
    token=$(_lokistack_token) && _grafana_add_datasource loki "$(_loki_ds_gateway "$gw" "$token")"
  elif oc -n "$OBS_NS" get svc loki >/dev/null 2>&1; then               # helm Loki
    _grafana_add_datasource loki "$(_loki_ds_plain "http://loki.$OBS_NS.svc:3100")"
  fi
  if oc -n "$OBS_NS" get svc tempo-tempo-query-frontend >/dev/null 2>&1; then   # operator Tempo
    _grafana_add_datasource tempo "$(_tempo_ds "http://tempo-tempo-query-frontend.$OBS_NS.svc:3200")"
  elif oc -n "$OBS_NS" get svc tempo >/dev/null 2>&1; then              # helm Tempo
    _grafana_add_datasource tempo "$(_tempo_ds "http://tempo.$OBS_NS.svc:3200")"
  fi
  return 0
}

# ── Alloy log shipper (DaemonSet) — used by BOTH Loki methods ──────────────
# _install_alloy <loki-push-url> [tenant] [bearer-token]
# Grafana Alloy tails pod logs on every node and pushes to Loki.
_install_alloy() {
  local push=$1 tenant=${2:-} bearer=${3:-} ver
  _need_helm || return 1
  # Alloy reads host log dirs (hostPath) — anyuid isn't enough for that, so the
  # Alloy SA gets the broader 'privileged' SCC (scoped to its own SA only).
  oc -n "$OBS_NS" create serviceaccount alloy --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc adm policy add-scc-to-group privileged "system:serviceaccounts:$OBS_NS" >/dev/null 2>&1 || true
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update grafana >/dev/null 2>&1 || true
  ver=$(_helm_n2_version grafana/alloy)
  # optional X-Scope-OrgID tenant id (only when pushing straight to a Loki that
  # expects it; the LokiStack gateway carries the tenant in the URL path instead)
  local tenant_line=""
  [ -n "$tenant" ] && tenant_line="
    tenant_id = \"$tenant\""
  # optional bearer token (LokiStack gateway authenticates via an OpenShift SA token)
  local bearer_line=""
  [ -n "$bearer" ] && bearer_line="
    bearer_token = \"$bearer\""
  # LokiStack's internal :3100 endpoints serve HTTPS (service-CA cert) — skip
  # verification for the in-cluster push. (Helm single-binary uses plain http.)
  local tls_block=""
  case "$push" in
    https://*) tls_block="
    tls_config {
      insecure_skip_verify = true
    }" ;;
  esac
  # Alloy 'River' config: each attribute MUST be on its own line (the parser
  # rejects two attributes on one line). Discover pods -> relabel meta labels ->
  # tail logs via the Kubernetes API -> push to Loki.
  helm upgrade --install alloy grafana/alloy -n "$OBS_NS" ${ver:+--version "$ver"} \
    --set controller.type=daemonset \
    --set serviceAccount.create=false \
    --set serviceAccount.name=alloy \
    --set-string alloy.configMap.content="$(cat <<RIVER
discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets

  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_node_name"]
    target_label  = "node"
  }
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "$push"$tenant_line$bearer_line$tls_block
  }
}
RIVER
)" \
    --wait --timeout 5m >/dev/null 2>&1 \
    || echo "    Alloy helm reported an error — check: oc -n $OBS_NS get pods -l app.kubernetes.io/name=alloy"
}

# mint a long-lived SA token that can read+write the LokiStack 'application'
# tenant through the gateway. The gateway (opa-openshift) authorizes WRITES via
# a SubjectAccessReview on loki.grafana.com/<tenant>, but authorizes application
# READS via core pod/namespace RBAC (it filters logs to namespaces the subject
# can view) — hence the scoped pods/namespaces read rule. Echoes the token.
_lokistack_token() {
  oc -n "$OBS_NS" create serviceaccount loki-access --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc apply -f - >/dev/null <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: ${OBS_NS}-loki-logs }
rules:
- apiGroups: [loki.grafana.com]
  resources: [application, infrastructure, audit]
  verbs: [get, create]
- apiGroups: [""]
  resources: [pods, namespaces]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: ${OBS_NS}-loki-logs }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: ${OBS_NS}-loki-logs }
subjects:
- { kind: ServiceAccount, name: loki-access, namespace: ${OBS_NS} }
RBAC
  oc apply -f - >/dev/null <<TOK
apiVersion: v1
kind: Secret
metadata:
  name: loki-access-token
  namespace: ${OBS_NS}
  annotations: { kubernetes.io/service-account.name: loki-access }
type: kubernetes.io/service-account-token
TOK
  local t=0 token=""
  until token=$(oc -n "$OBS_NS" get secret loki-access-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d) \
        && [ -n "$token" ]; do
    t=$((t+1)); [ $t -le 30 ] || return 1; sleep 2
  done
  echo "$token"
}

# ── Loki (logs) ────────────────────────────────────────────────────────────
install_loki() {
  local method=${1:-helm} sc
  log "Installing Loki (logs) — method: $method — EXPERIMENTAL"
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  loki        : FAILED — no usable storageclass"; return 1; }
  _obs_ns
  sc=$(_default_sc)

  if [ "$method" = operator ]; then
    _ensure_minio
    _minio_s3_secret loki-s3 bucketnames loki us-east-1
    # loki-operator supports AllNamespaces; install into openshift-operators
    # (which already has an all-namespaces OperatorGroup), like cert-manager.
    _subscribe openshift-operators loki-operator loki-operator alpha
    _wait_csv openshift-operators 300 loki-operator || { DEVOPS_NOTE="$DEVOPS_NOTE
  loki        : operator install FAILED — check: oc -n openshift-operators get csv,sub"; return 1; }
    local t=0
    until oc get crd lokistacks.loki.grafana.com >/dev/null 2>&1; do
      t=$((t+1)); [ $t -le 30 ] || { echo "    LokiStack CRD never appeared"; return 1; }; sleep 5
    done
    oc apply -f - >/dev/null <<LOKISTACK
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata: { name: logging, namespace: $OBS_NS }
spec:
  size: 1x.demo
  storageClassName: $sc
  storage:
    secret: { name: loki-s3, type: s3 }
    schemas:
    - version: v13
      effectiveDate: "2024-01-01"
  tenants: { mode: openshift-logging }
LOKISTACK
    oc -n "$OBS_NS" wait lokistack/logging --for=condition=Ready --timeout=420s >/dev/null 2>&1 \
      || echo "    LokiStack still settling — check: oc -n $OBS_NS get lokistack logging -o yaml"
    # All log traffic goes through the gateway (HTTPS, OpenShift-token auth, tenant
    # in the URL path) — the internal :3100 ports are mTLS metrics endpoints, not
    # the log API. Mint an SA token with RBAC for the 'application' tenant.
    local gw="https://logging-gateway-http.$OBS_NS.svc:8080/api/logs/v1/application"
    local token; token=$(_lokistack_token) || echo "    could not mint LokiStack access token"
    _install_alloy "$gw/loki/api/v1/push" "" "$token"
    _grafana_add_datasource loki "$(_loki_ds_gateway "$gw" "$token")"
    DEVOPS_NOTE="$DEVOPS_NOTE
  loki        : LokiStack 'logging' (operator, S3=MinIO) via gateway $gw
                logs in Grafana -> Explore -> Loki (tenant: application)"
    return 0
  fi

  # ── helm single-binary ──
  _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  loki        : FAILED — helm not installed"; return 1; }
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update grafana >/dev/null 2>&1 || true
  local ver; ver=$(_helm_n2_version grafana/loki)
  [ -n "$ver" ] && echo "    pinning chart grafana/loki to $ver [policy $VERSION_POLICY]"
  helm upgrade --install loki grafana/loki -n "$OBS_NS" ${ver:+--version "$ver"} \
    --set deploymentMode=SingleBinary \
    --set singleBinary.replicas=1 \
    --set singleBinary.persistence.storageClass="$sc" \
    --set singleBinary.persistence.size=10Gi \
    --set 'loki.auth_enabled=false' \
    --set loki.commonConfig.replication_factor=1 \
    --set loki.storage.type=filesystem \
    --set-json 'loki.schemaConfig={"configs":[{"from":"2024-01-01","store":"tsdb","object_store":"filesystem","schema":"v13","index":{"prefix":"index_","period":"24h"}}]}' \
    --set chunksCache.enabled=false \
    --set resultsCache.enabled=false \
    --set test.enabled=false \
    --set lokiCanary.enabled=false \
    --set monitoring.selfMonitoring.enabled=false \
    --set monitoring.selfMonitoring.grafanaAgent.installOperator=false \
    --set read.replicas=0 --set write.replicas=0 --set backend.replicas=0 \
    --set gateway.enabled=false \
    --wait --timeout 8m >/dev/null 2>&1 \
    || echo "    Loki helm reported a timeout/error — may still be settling; check: oc -n $OBS_NS get pods"
  # gateway disabled (its bundled nginx hardcodes a kube-dns resolver that does
  # not exist on OpenShift) — talk to the single-binary 'loki' service directly.
  local query="http://loki.$OBS_NS.svc:3100"
  _install_alloy "$query/loki/api/v1/push"
  _grafana_add_datasource loki "$(_loki_ds_plain "$query")"
  DEVOPS_NOTE="$DEVOPS_NOTE
  loki        : grafana/loki single-binary (helm, filesystem). Query $query
                logs in Grafana -> Explore -> Loki"
  return 0
}

# ── Tempo (traces) ───────────────────────────────────────────────────────
# resolves the OTLP endpoint apps/OTel should send traces to (helm vs operator)
_tempo_otlp_endpoint() {
  # operator (TempoStack 'tempo' -> 'tempo-tempo-distributor') vs helm ('tempo')
  if oc -n "$OBS_NS" get svc tempo-tempo-distributor >/dev/null 2>&1; then
    echo "tempo-tempo-distributor.$OBS_NS.svc:4317"
  else
    echo "tempo.$OBS_NS.svc:4317"
  fi
}

install_tempo() {
  local method=${1:-helm} sc query
  log "Installing Tempo (traces) — method: $method — EXPERIMENTAL"
  ensure_storage_backend || { DEVOPS_NOTE="$DEVOPS_NOTE
  tempo       : FAILED — no usable storageclass"; return 1; }
  _obs_ns
  sc=$(_default_sc)

  if [ "$method" = operator ]; then
    _ensure_minio
    _minio_s3_secret tempo-s3 bucket tempo
    _subscribe openshift-operators tempo-operator tempo-operator alpha
    _wait_csv openshift-operators 300 tempo-operator || { DEVOPS_NOTE="$DEVOPS_NOTE
  tempo       : operator install FAILED — check: oc -n openshift-operators get csv,sub"; return 1; }
    local t=0
    until oc get crd tempostacks.tempo.grafana.com >/dev/null 2>&1; do
      t=$((t+1)); [ $t -le 30 ] || { echo "    TempoStack CRD never appeared"; return 1; }; sleep 5
    done
    oc apply -f - >/dev/null <<TEMPOSTACK
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata: { name: tempo, namespace: $OBS_NS }
spec:
  storageSize: 10Gi
  storage:
    secret: { name: tempo-s3, type: s3 }
  template:
    queryFrontend:
      jaegerQuery: { enabled: true }
TEMPOSTACK
    oc -n "$OBS_NS" wait tempostack/tempo --for=condition=Ready --timeout=420s >/dev/null 2>&1 \
      || echo "    TempoStack still settling — check: oc -n $OBS_NS get tempostack tempo -o yaml"
    query="http://tempo-tempo-query-frontend.$OBS_NS.svc:3200"
    _grafana_add_datasource tempo "$(_tempo_ds "$query")"
    DEVOPS_NOTE="$DEVOPS_NOTE
  tempo       : TempoStack 'tempo' (operator, S3=MinIO). OTLP -> $(_tempo_otlp_endpoint)
                traces in Grafana -> Explore -> Tempo"
    return 0
  fi

  # ── helm monolithic single-binary ──
  _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  tempo       : FAILED — helm not installed"; return 1; }
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update grafana >/dev/null 2>&1 || true
  local ver; ver=$(_helm_n2_version grafana/tempo)
  [ -n "$ver" ] && echo "    pinning chart grafana/tempo to $ver [policy $VERSION_POLICY]"
  helm upgrade --install tempo grafana/tempo -n "$OBS_NS" ${ver:+--version "$ver"} \
    --set tempo.storage.trace.backend=local \
    --set persistence.enabled=true \
    --set persistence.storageClassName="$sc" \
    --set persistence.size=10Gi \
    --set-json 'tempo.receivers={"otlp":{"protocols":{"grpc":{"endpoint":"0.0.0.0:4317"},"http":{"endpoint":"0.0.0.0:4318"}}}}' \
    --wait --timeout 8m >/dev/null 2>&1 \
    || echo "    Tempo helm reported a timeout/error — may still be settling; check: oc -n $OBS_NS get pods"
  query="http://tempo.$OBS_NS.svc:3200"
  _grafana_add_datasource tempo "$(_tempo_ds "$query")"
  DEVOPS_NOTE="$DEVOPS_NOTE
  tempo       : grafana/tempo monolithic (helm, local). OTLP -> $(_tempo_otlp_endpoint)
                traces in Grafana -> Explore -> Tempo"
  return 0
}

# ── OpenTelemetry Collector (pipeline) ─────────────────────────────────────
# Receives OTLP and fans out: traces -> Tempo, metrics -> a Prometheus endpoint
# (:8889) scraped by UWM. Logs are handled by Alloy (the OTel 'loki' exporter
# was removed upstream), so OTel here is traces + metrics.
install_otel() {
  local method=${1:-helm} tempo_otlp
  log "Installing OpenTelemetry Collector — method: $method — EXPERIMENTAL"
  _obs_ns
  tempo_otlp=$(_tempo_otlp_endpoint)

  # the collector config is identical for both methods
  local otelcfg
  otelcfg=$(cat <<OTELCFG
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }
processors:
  batch: {}
exporters:
  otlp/tempo:
    endpoint: $tempo_otlp
    tls: { insecure: true }
  prometheus:
    endpoint: 0.0.0.0:8889
service:
  pipelines:
    traces:  { receivers: [otlp], processors: [batch], exporters: [otlp/tempo] }
    metrics: { receivers: [otlp], processors: [batch], exporters: [prometheus] }
OTELCFG
)

  if [ "$method" = operator ]; then
    _subscribe openshift-operators opentelemetry-operator opentelemetry-operator alpha
    _wait_csv openshift-operators 300 opentelemetry-operator || { DEVOPS_NOTE="$DEVOPS_NOTE
  otel        : operator install FAILED — check: oc -n openshift-operators get csv,sub"; return 1; }
    local t=0
    until oc get crd opentelemetrycollectors.opentelemetry.io >/dev/null 2>&1; do
      t=$((t+1)); [ $t -le 30 ] || { echo "    OpenTelemetryCollector CRD never appeared"; return 1; }; sleep 5
    done
    # spec.config takes the collector YAML (indented under the CR)
    {
      echo "apiVersion: opentelemetry.io/v1beta1"
      echo "kind: OpenTelemetryCollector"
      echo "metadata: { name: otel, namespace: $OBS_NS }"
      echo "spec:"
      echo "  mode: deployment"
      # contrib distro: the default operator image lacks the 'prometheus' exporter
      echo "  image: otel/opentelemetry-collector-contrib:0.153.0"
      echo "  config:"
      echo "$otelcfg" | sed 's/^/    /'
    } | oc apply -f - >/dev/null \
      || echo "    OpenTelemetryCollector apply failed (v1beta1 config schema?) — check: oc -n $OBS_NS get opentelemetrycollector"
    oc -n "$OBS_NS" rollout status deploy/otel-collector --timeout=180s >/dev/null 2>&1 || true
  else
    _need_helm || { DEVOPS_NOTE="$DEVOPS_NOTE
  otel        : FAILED — helm not installed"; return 1; }
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
    helm repo update open-telemetry >/dev/null 2>&1 || true
    local ver; ver=$(_helm_n2_version open-telemetry/opentelemetry-collector)
    [ -n "$ver" ] && echo "    pinning chart open-telemetry/opentelemetry-collector to $ver [policy $VERSION_POLICY]"
    helm upgrade --install otel-collector open-telemetry/opentelemetry-collector -n "$OBS_NS" ${ver:+--version "$ver"} \
      --set mode=deployment \
      --set fullnameOverride=otel-collector \
      --set image.repository=otel/opentelemetry-collector-contrib \
      --set command.name=otelcol-contrib \
      --set-json 'ports={"otlp":{"enabled":true,"containerPort":4317,"servicePort":4317,"protocol":"TCP"},"otlp-http":{"enabled":true,"containerPort":4318,"servicePort":4318,"protocol":"TCP"},"metrics":{"enabled":true,"containerPort":8889,"servicePort":8889,"protocol":"TCP"}}' \
      --set-json "config=$(echo "$otelcfg" | _yaml2json)" \
      --wait --timeout 6m >/dev/null 2>&1 \
      || echo "    OTel helm reported a timeout/error — check: oc -n $OBS_NS get pods -l app.kubernetes.io/name=opentelemetry-collector"
  fi

  # ServiceMonitor so UWM Prometheus scrapes the :8889 metrics (harmless if UWM off)
  oc apply -f - >/dev/null 2>&1 <<SM || true
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: otel-collector, namespace: $OBS_NS }
spec:
  selector:
    matchLabels: { app.kubernetes.io/name: opentelemetry-collector }
  endpoints:
  - port: metrics
SM
  DEVOPS_NOTE="$DEVOPS_NOTE
  otel        : OpenTelemetry Collector ($method). Send OTLP to
                otel-collector.$OBS_NS.svc:4317 (gRPC) / :4318 (HTTP); traces -> Tempo, metrics -> :8889"
  return 0
}

# tiny YAML->JSON for passing the collector config to the helm chart's --set-json
_yaml2json() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)'
  else
    # fall back: assume yq is present; otherwise the helm install will error out
    yq -o=json eval - 2>/dev/null
  fi
}

# ── Jaeger UI — expose the Tempo operator's built-in Jaeger query UI ────────
# No separate trace store: the operator TempoStack already runs a Jaeger-compatible
# query UI (template.queryFrontend.jaegerQuery). This ensures operator Tempo exists
# and routes its Jaeger UI. (Helm single-binary Tempo has no Jaeger UI — use Grafana's
# Tempo datasource there. Point mesh/app tracing at tempo-tempo-distributor:4317.)
install_jaeger() {
  log "Exposing Jaeger UI via the Tempo operator (TempoStack) — EXPERIMENTAL"
  _obs_ns
  if ! oc -n "$OBS_NS" get tempostack tempo >/dev/null 2>&1; then
    echo "    operator Tempo not present — installing it (the Jaeger UI lives on its query-frontend)"
    install_tempo operator || { DEVOPS_NOTE="$DEVOPS_NOTE
  jaeger      : FAILED — operator Tempo (TempoStack) unavailable"; return 1; }
  fi
  local ingd; ingd=$(_ingress_domain)
  # the query-frontend service exposes the Jaeger UI on 16686 (named port 'jaeger-ui')
  local pname
  pname=$(oc -n "$OBS_NS" get svc tempo-tempo-query-frontend -o json 2>/dev/null \
    | jq -r '.spec.ports[]? | select(.port==16686) | .name' | head -1)
  [ -n "$pname" ] || pname=jaeger-ui
  _make_route "$OBS_NS" jaeger tempo-tempo-query-frontend "$pname" "jaeger.$ingd"
  DEVOPS_NOTE="$DEVOPS_NOTE
  jaeger      : https://jaeger.$ingd  (Tempo's Jaeger UI; send OTLP traces to
                tempo-tempo-distributor.$OBS_NS.svc:4317 — Kiali links to it)"
  return 0
}
