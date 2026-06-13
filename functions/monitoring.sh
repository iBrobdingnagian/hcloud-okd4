#!/usr/bin/env bash
# functions/monitoring.sh — monitoring & alerting stack (UWM, Alertmanager, Grafana)
# Sourced by deploy-okd.sh; not meant to be executed directly.

# ── monitoring & alerting (user-workload monitoring + Alertmanager) ─────
# The full stack (extra Prometheus pair, Thanos ruler) is too heavy for
# minimal lab nodes, so it is gated: at least one schedulable node must
# have MORE than 12 GB RAM. Works during a deploy and on a running cluster.
MONITORING_NOTE="monitoring  : not configured (re-run ./deploy-okd.sh --monitoring to add it)"

max_node_ram_gb() {  # largest memory capacity (GB, integer) among schedulable Ready nodes
  oc get nodes -o json 2>/dev/null | jq -r '
    [ .items[]
      | select(.spec.unschedulable != true)
      | .status.capacity.memory
      | capture("(?<n>[0-9]+)(?<u>[A-Za-z]*)")
      | (.n | tonumber) * (if   .u == "Ki" then 1 / 1048576
                           elif .u == "Mi" then 1 / 1024
                           elif .u == "Gi" then 1
                           else 1 / 1073741824 end)
    ] | max // 0 | floor'
}

install_monitoring() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  [ -f "$KUBECONFIG" ] || { echo "    no kubeconfig at $KUBECONFIG — cannot configure monitoring"; return 1; }
  local max_gb t
  max_gb=$(max_node_ram_gb)
  if ! awk -v g="${max_gb:-0}" 'BEGIN{exit !(g+0>12)}'; then
    echo "    monitoring needs a node with more than 12 GB RAM — largest schedulable node has ${max_gb:-0} GB; skipping"
    MONITORING_NOTE="monitoring  : SKIPPED (needs a node with >12 GB RAM, largest is ${max_gb:-0} GB)"
    return 1
  fi
  log "Configuring monitoring & alerting (largest node: ${max_gb} GB RAM)"
  oc apply -f - <<'MONEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
    alertmanagerMain:
      enableUserAlertmanagerConfig: true
    prometheusK8s:
      retention: 24h
MONEOF

  if [ -z "$ALERT_WEBHOOK" ] && [ "$ASSUME_YES" = 0 ]; then
    printf 'Alertmanager webhook URL for warning/critical alerts (Slack/Teams/generic; empty to skip): '
    read -r ALERT_WEBHOOK
  fi
  if [ -n "$ALERT_WEBHOOK" ]; then
    echo "    routing warning/critical alerts to $ALERT_WEBHOOK"
    local amtmp
    amtmp=$(mktemp)
    cat > "$amtmp" <<AMEOF
global:
  resolve_timeout: 5m
route:
  group_by: ['namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: default
  routes:
  - receiver: watchdog
    matchers:
    - alertname = Watchdog
  - receiver: webhook
    matchers:
    - severity =~ "warning|critical"
receivers:
- name: default
- name: watchdog
- name: webhook
  webhook_configs:
  - url: '$ALERT_WEBHOOK'
AMEOF
    oc -n openshift-monitoring create secret generic alertmanager-main \
      --from-file=alertmanager.yaml="$amtmp" --dry-run=client -o yaml | oc replace -f -
    rm -f "$amtmp"
  fi

  echo "    waiting for the user-workload monitoring stack (1-3 min typical)"
  t=0
  until [ "$(oc -n openshift-user-workload-monitoring get pods --no-headers 2>/dev/null \
             | awk '$3=="Running"' | wc -l | tr -d ' ')" -ge 3 ]; do
    t=$((t+1))
    if [ $t -gt 30 ]; then
      echo "    still starting — check later with: oc -n openshift-user-workload-monitoring get pods"
      break
    fi
    sleep 10
  done
  oc -n openshift-user-workload-monitoring get pods 2>/dev/null || true
  MONITORING_NOTE="monitoring  : user-workload monitoring + alerting enabled (console -> Observe)"
  [ -n "$ALERT_WEBHOOK" ] && MONITORING_NOTE="$MONITORING_NOTE
  alerts      : warning/critical routed to $ALERT_WEBHOOK"
  install_grafana || MONITORING_NOTE="$MONITORING_NOTE
  grafana     : install FAILED — check: oc -n grafana get pods"
  return 0
}

install_grafana() {
  # OKD 4.16 no longer bundles Grafana, so deploy the upstream image and
  # point it at thanos-querier (platform + user-workload metrics) with a
  # cluster-monitoring-view service-account token
  log "Deploying Grafana for visualization"
  oc get ns grafana >/dev/null 2>&1 || oc create namespace grafana
  oc -n grafana create serviceaccount grafana --dry-run=client -o yaml | oc apply -f -
  oc adm policy add-cluster-role-to-user cluster-monitoring-view -z grafana -n grafana >/dev/null
  # a long-lived SA token secret (TokenRequest tokens expire within hours)
  oc apply -f - <<'GTOK'
apiVersion: v1
kind: Secret
metadata:
  name: grafana-sa-token
  namespace: grafana
  annotations:
    kubernetes.io/service-account.name: grafana
type: kubernetes.io/service-account-token
GTOK
  local token="" t=0 pass dstmp
  until token=$(oc -n grafana get secret grafana-sa-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d) \
        && [ -n "$token" ]; do
    t=$((t+1))
    [ $t -le 30 ] || { echo "    service-account token was not issued"; return 1; }
    sleep 2
  done
  # admin password survives re-runs so existing logins keep working
  if oc -n grafana get secret grafana-admin >/dev/null 2>&1; then
    pass=$(oc -n grafana get secret grafana-admin -o jsonpath='{.data.password}' | base64 -d)
  else
    pass=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)
    oc -n grafana create secret generic grafana-admin --from-literal=password="$pass"
  fi
  dstmp=$(mktemp)
  cat > "$dstmp" <<DSEOF
apiVersion: 1
datasources:
- name: OpenShift Prometheus
  type: prometheus
  access: proxy
  isDefault: true
  url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
  jsonData:
    httpHeaderName1: Authorization
    tlsSkipVerify: true
    timeInterval: 30s
  secureJsonData:
    httpHeaderValue1: Bearer $token
DSEOF
  oc -n grafana create configmap grafana-datasources --from-file=datasources.yaml="$dstmp" \
    --dry-run=client -o yaml | oc apply -f -
  # dashboards: grafana/dashboards/<category>/*.json — each category becomes
  # a Grafana folder (regenerate with: python3 grafana/gen-dashboards.py)
  if [ -d grafana/dashboards ]; then
    cat > "$dstmp" <<'DBPEOF'
apiVersion: 1
providers:
- { name: cluster,       orgId: 1, folder: 'Cluster',       type: file, disableDeletion: false, updateIntervalSeconds: 30, options: { path: /var/lib/grafana/dashboards/cluster } }
- { name: control-plane, orgId: 1, folder: 'Control Plane', type: file, disableDeletion: false, updateIntervalSeconds: 30, options: { path: /var/lib/grafana/dashboards/control-plane } }
- { name: nodes,         orgId: 1, folder: 'Nodes',         type: file, disableDeletion: false, updateIntervalSeconds: 30, options: { path: /var/lib/grafana/dashboards/nodes } }
- { name: workloads,     orgId: 1, folder: 'Workloads',     type: file, disableDeletion: false, updateIntervalSeconds: 30, options: { path: /var/lib/grafana/dashboards/workloads } }
- { name: network,       orgId: 1, folder: 'Network',       type: file, disableDeletion: false, updateIntervalSeconds: 30, options: { path: /var/lib/grafana/dashboards/network } }
- { name: storage,       orgId: 1, folder: 'Storage',       type: file, disableDeletion: false, updateIntervalSeconds: 30, options: { path: /var/lib/grafana/dashboards/storage } }
- { name: onzack,        orgId: 1, folder: 'ONZACK',        type: file, disableDeletion: false, updateIntervalSeconds: 30, options: { path: /var/lib/grafana/dashboards/onzack } }
DBPEOF
    oc -n grafana create configmap grafana-dashboard-provider \
      --from-file=dashboards.yaml="$dstmp" --dry-run=client -o yaml | oc apply -f -
    local cat
    for cat in cluster control-plane nodes workloads network storage; do
      [ -d "grafana/dashboards/$cat" ] || continue
      oc -n grafana create configmap "grafana-dashboards-$cat" \
        --from-file="grafana/dashboards/$cat/" --dry-run=client -o yaml | oc apply -f -
    done
    # the pre-category flat configmap is no longer mounted
    oc -n grafana delete configmap grafana-dashboards --ignore-not-found >/dev/null
  fi
  # vendored third-party dashboards (ONZACK) live OUTSIDE grafana/dashboards/
  # because gen-dashboards.py rmtree's that tree on every regenerate. We use
  # the "without-recording-rules" variants: they run the full queries inline
  # against thanos-querier (which federates platform + UWM metrics), so they
  # need no PrometheusRule — see grafana/vendor/onzack/rules/README for why
  # the recording-rules variant cannot populate on OKD's split stack.
  if ls grafana/vendor/onzack/*.json >/dev/null 2>&1; then
    local ozargs=() j
    for j in grafana/vendor/onzack/*.json; do ozargs+=(--from-file="$j"); done
    # server-side apply: the two dashboards total ~536 KB, which overflows the
    # 262144-byte kubectl.kubernetes.io/last-applied-configuration annotation
    # that client-side `oc apply` writes. Server-side apply stores no such
    # annotation (the object only needs to stay under the ~1 MB etcd limit).
    oc -n grafana create configmap grafana-dashboards-onzack \
      "${ozargs[@]}" --dry-run=client -o yaml \
      | oc apply --server-side --force-conflicts -f -
  fi
  rm -f "$dstmp"
  oc apply -f - <<GRAFANA
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      serviceAccountName: grafana
      containers:
      - name: grafana
        image: docker.io/grafana/grafana:11.6.0
        ports:
        - containerPort: 3000
          name: http
        env:
        - name: GF_SECURITY_ADMIN_USER
          value: admin
        - name: GF_SECURITY_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: grafana-admin
              key: password
        readinessProbe:
          httpGet:
            path: /api/health
            port: 3000
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 1Gi
        volumeMounts:
        - name: data
          mountPath: /var/lib/grafana
        - name: datasources
          mountPath: /etc/grafana/provisioning/datasources
        - name: dashboard-provider
          mountPath: /etc/grafana/provisioning/dashboards
        - name: db-cluster
          mountPath: /var/lib/grafana/dashboards/cluster
        - name: db-control-plane
          mountPath: /var/lib/grafana/dashboards/control-plane
        - name: db-nodes
          mountPath: /var/lib/grafana/dashboards/nodes
        - name: db-workloads
          mountPath: /var/lib/grafana/dashboards/workloads
        - name: db-network
          mountPath: /var/lib/grafana/dashboards/network
        - name: db-storage
          mountPath: /var/lib/grafana/dashboards/storage
        - name: db-onzack
          mountPath: /var/lib/grafana/dashboards/onzack
      volumes:
      - name: data
        emptyDir: {}
      - name: datasources
        configMap:
          name: grafana-datasources
      - name: dashboard-provider
        configMap:
          name: grafana-dashboard-provider
          optional: true
      - name: db-cluster
        configMap:
          name: grafana-dashboards-cluster
          optional: true
      - name: db-control-plane
        configMap:
          name: grafana-dashboards-control-plane
          optional: true
      - name: db-nodes
        configMap:
          name: grafana-dashboards-nodes
          optional: true
      - name: db-workloads
        configMap:
          name: grafana-dashboards-workloads
          optional: true
      - name: db-network
        configMap:
          name: grafana-dashboards-network
          optional: true
      - name: db-storage
        configMap:
          name: grafana-dashboards-storage
          optional: true
      - name: db-onzack
        configMap:
          name: grafana-dashboards-onzack
          optional: true
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: grafana
spec:
  selector:
    app: grafana
  ports:
  - port: 3000
    targetPort: 3000
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: grafana
  namespace: grafana
spec:
  host: grafana.apps.$DOMAIN
  to:
    kind: Service
    name: grafana
  port:
    targetPort: 3000
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
GRAFANA
  # restart so config-only changes (datasource/dashboards) are picked up on re-runs
  oc -n grafana rollout restart deploy/grafana >/dev/null
  oc -n grafana rollout status deploy/grafana --timeout=300s \
    || { echo "    Grafana did not become ready — check: oc -n grafana get pods"; return 1; }
  MONITORING_NOTE="$MONITORING_NOTE
  grafana     : https://grafana.apps.$DOMAIN  (user: admin, password: $pass)"
  return 0
}
