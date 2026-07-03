#!/usr/bin/env bash
# functions/appsim.sh — real-world application-simulation scenarios
# Sourced by deploy-okd.sh; not meant to be executed directly.
#
# Extends the single Kafka traffic generator (install_appsim, functions/devops.sh)
# into a SUITE of simulations that exercise the DevOps toolchain the repo installs,
# the way real deployments would:
#
#   appsim-gitops    podinfo + helm-guestbook deployed by ArgoCD from Git (+ traffic)
#   appsim-boutique  GoogleCloud "Online Boutique" (11 microservices + Locust loadgen)
#   appsim-events    Strimzi/Kafka java client-examples (producer/consumer/streams)
#   appsim-awx       an AWX project + job-template playbook that automates a cluster action
#   appsim-cicd      full CI/CD GitOps loop: Jenkins (kaniko) -> Harbor -> GitLab -> ArgoCD
#
# Each installer is best-effort (EXPERIMENTAL), self-bootstraps its prerequisite tool
# (like install_appsim calls install_kafka/install_strimzi), reuses functions/devops.sh
# helpers (_devops_ns, _default_sc, _ingress_domain, _make_route, _api_url,
# ensure_storage_backend, _strimzi_app_user) and appends to DEVOPS_NOTE.

# ── ArgoCD helpers ─────────────────────────────────────────────────────────
# ensure the ArgoCD operator + an ArgoCD instance named 'argocd' are present
_appsim_need_argocd() {
  if oc get crd applications.argoproj.io >/dev/null 2>&1 \
     && oc -n argocd get argocd argocd >/dev/null 2>&1; then return 0; fi
  install_argocd
  local t=0
  until oc get crd applications.argoproj.io >/dev/null 2>&1; do
    t=$((t+1)); [ $t -le 30 ] || return 1; sleep 5
  done
}

# _argocd_app <name> <dest-ns> <repoURL> <path> <revision> [helm-values]
# create an Application (auto-sync, prune, selfHeal, CreateNamespace) in the argocd
# namespace and label the destination ns so the operator grants the controller RBAC.
_argocd_app() {
  local name=$1 dns=$2 repo=$3 path=$4 rev=$5 vals=${6:-} helmblock=""
  _devops_ns "$dns"
  oc label ns "$dns" argocd.argoproj.io/managed-by=argocd --overwrite >/dev/null 2>&1 || true
  if [ -n "$vals" ]; then
    # helm: aligns with repoURL/path (4 spaces under source:); values content 8 spaces
    helmblock="
    helm:
      values: |
$(printf '%s\n' "$vals" | sed 's/^/        /')"
  fi
  oc apply -f - >/dev/null <<APP
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $name
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $repo
    path: $path
    targetRevision: $rev$helmblock
  destination:
    server: https://kubernetes.default.svc
    namespace: $dns
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
APP
}

# ── appsim-gitops: podinfo via ArgoCD ──────────────────────────────────────
PODINFO_REPO=${PODINFO_REPO:-https://github.com/stefanprodan/podinfo}

install_appsim_gitops() {
  log "AppSim/GitOps: podinfo deployed by ArgoCD (Helm chart from Git)"
  _appsim_need_argocd || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-gitops: FAILED — ArgoCD unavailable"; return 1; }
  local ns=appsim-gitops ingd; ingd=$(_ingress_domain)

  # podinfo: Helm chart straight from its git repo (no chart-version pin needed).
  # Canonical GitOps demo, runs cleanly under OpenShift's restricted SCC.
  _argocd_app podinfo "$ns" "$PODINFO_REPO" charts/podinfo master "ui:
  message: \"deployed by ArgoCD (appsim-gitops)\"
serviceMonitor:
  enabled: false"

  # give ArgoCD a moment to create the podinfo Service, then route + traffic-gen
  local t=0
  until oc -n "$ns" get svc podinfo >/dev/null 2>&1; do
    t=$((t+1)); [ $t -le 36 ] || { echo "    podinfo Service not synced yet — ArgoCD will reconcile; check: oc -n argocd get app podinfo"; break; }
    sleep 5
  done
  [ -n "$ingd" ] && oc -n "$ns" get svc podinfo >/dev/null 2>&1 && _make_route "$ns" podinfo podinfo http "podinfo.$ingd"

  # traffic generator: hammer podinfo's endpoints so dashboards/metrics show load
  oc apply -f - >/dev/null <<'TG'
apiVersion: apps/v1
kind: Deployment
metadata: { name: traffic-gen, namespace: appsim-gitops }
spec:
  replicas: 1
  selector: { matchLabels: { app: traffic-gen } }
  template:
    metadata: { labels: { app: traffic-gen } }
    spec:
      containers:
      - name: curl
        image: curlimages/curl:latest
        command: ["/bin/sh","-c"]
        args:
        - |
          base=http://podinfo.appsim-gitops.svc:9898
          while true; do
            curl -s -o /dev/null "$base/" || true
            curl -s -o /dev/null "$base/api/info" || true
            curl -s -o /dev/null "$base/healthz" || true
            curl -s -o /dev/null "$base/delay/1" || true
            sleep 1
          done
        resources:
          requests: { cpu: 20m, memory: 32Mi }
          limits:   { memory: 64Mi }
TG

  DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-gitops: ArgoCD app 'podinfo' in ns $ns (oc -n argocd get app podinfo)
                 podinfo: ${ingd:+https://podinfo.$ingd}  traffic-gen running"
  return 0
}

# ── appsim-boutique: GoogleCloud Online Boutique via ArgoCD ────────────────
BOUTIQUE_REPO=${BOUTIQUE_REPO:-https://github.com/GoogleCloudPlatform/microservices-demo}

install_appsim_boutique() {
  log "AppSim/Boutique: Online Boutique (11 microservices + Locust) via ArgoCD — heavy/EXPERIMENTAL"
  _appsim_need_argocd || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-boutique: FAILED — ArgoCD unavailable"; return 1; }
  local ns=appsim-boutique ingd; ingd=$(_ingress_domain)
  _devops_ns "$ns"
  # some Boutique containers expect fixed/non-root uids — anyuid (RunAsAny) admits them
  oc adm policy add-scc-to-group anyuid system:serviceaccounts:"$ns" >/dev/null 2>&1 || true

  _argocd_app boutique "$ns" "$BOUTIQUE_REPO" helm-chart main

  # route to the storefront once ArgoCD has created the frontend Service
  local t=0
  until oc -n "$ns" get svc frontend >/dev/null 2>&1; do
    t=$((t+1)); [ $t -le 48 ] || { echo "    frontend Service not synced yet — check: oc -n argocd get app boutique"; break; }
    sleep 5
  done
  [ -n "$ingd" ] && oc -n "$ns" get svc frontend >/dev/null 2>&1 && _make_route "$ns" boutique frontend http "boutique.$ingd"

  DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-boutique: ArgoCD app 'boutique' in ns $ns (~11 services + built-in Locust loadgen)
                   store: ${ingd:+https://boutique.$ingd}  (heavy — give it a few minutes)"
  return 0
}

# ── appsim-events: Kafka event pipeline (Strimzi java client-examples) ──────
# Real Java clients (richer than the console-script appsim): producer -> source
# topic -> Kafka Streams (uppercases) -> target topic -> consumer. Backend is
# classic Kafka (plaintext) or Strimzi (mTLS), like install_appsim.
EVENTS_PRODUCER_IMAGE=${EVENTS_PRODUCER_IMAGE:-quay.io/strimzi-examples/java-kafka-producer:latest}
EVENTS_CONSUMER_IMAGE=${EVENTS_CONSUMER_IMAGE:-quay.io/strimzi-examples/java-kafka-consumer:latest}
EVENTS_STREAMS_IMAGE=${EVENTS_STREAMS_IMAGE:-quay.io/strimzi-examples/java-kafka-streams:latest}

# dedicated Strimzi user for the events pipeline: broad-but-scoped ACLs over the
# 'appsim' prefix (covers source/target topics, the consumer group, and the
# Streams app's internal changelog/repartition topics named <app-id>-*).
_events_strimzi_user() {
  oc apply -f - >/dev/null <<USR
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: events-user
  namespace: strimzi
  labels: { strimzi.io/cluster: my-cluster }
spec:
  authentication: { type: tls }
  authorization:
    type: simple
    acls:
    - resource: { type: topic, name: appsim, patternType: prefix }
      operations: [Create, Describe, Read, Write]
    - resource: { type: group, name: appsim, patternType: prefix }
      operations: [Read, Describe]
    - resource: { type: cluster }
      operations: [DescribeConfigs]
USR
}

install_appsim_events() {
  log "AppSim/Events: Kafka pipeline producer -> streams -> consumer (Strimzi java clients)"
  local backend=${APPSIM_BACKEND:-}
  if [ -z "$backend" ]; then
    if [ "$ASSUME_YES" = 1 ] || [ -n "$FLAG_DEVOPS_COMPONENTS" ]; then backend=kafka
    else
      echo "    Backend? 1) Kafka+ZooKeeper (classic)  2) Strimzi (operator, mTLS)"
      printf '    Backend [1]: '; read -r B; case "${B:-1}" in 2) backend=strimzi ;; *) backend=kafka ;; esac
    fi
  fi
  local ns=appsim-events; _devops_ns "$ns"
  oc adm policy add-scc-to-group anyuid system:serviceaccounts:"$ns" >/dev/null 2>&1 || true

  local BOOT tls=0
  if [ "$backend" = strimzi ]; then
    oc get kafka my-cluster -n strimzi >/dev/null 2>&1 || install_strimzi || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-events: FAILED — Strimzi backend unavailable"; return 1; }
    _events_strimzi_user
    oc -n strimzi wait kafkauser/events-user --for=condition=Ready --timeout=300s 2>/dev/null \
      || echo "    events-user not Ready yet — clients will retry"
    # KafkaTopics (topic operator); Streams also makes internal appsim-streams-* topics
    local kt
    for kt in appsim-events appsim-events-out; do
      oc apply -f - >/dev/null <<TOP
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata: { name: $kt, namespace: strimzi, labels: { strimzi.io/cluster: my-cluster } }
spec: { partitions: 3, replicas: 1 }
TOP
    done
    # copy cluster CA + user cert into the app namespace (cross-ns mount isn't allowed)
    local s
    for s in my-cluster-cluster-ca-cert events-user; do
      oc -n strimzi get secret "$s" -o json 2>/dev/null \
        | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences,.metadata.managedFields,.status)' \
        | oc -n "$ns" apply -f - >/dev/null 2>&1 || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-events: FAILED — could not copy Strimzi secret '$s'"; return 1; }
    done
    BOOT="my-cluster-kafka-bootstrap.strimzi.svc:9093"; tls=1
  else
    backend=kafka
    oc -n kafka get statefulset kafka >/dev/null 2>&1 || install_kafka || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-events: FAILED — Kafka+ZooKeeper backend unavailable"; return 1; }
    BOOT="kafka.kafka.svc.cluster.local:9092"
  fi
  echo "    backend: $backend   bootstrap: $BOOT$([ "$tls" = 1 ] && echo '   (mTLS as events-user)')"

  # TLS env + cert mounts (Strimzi only); the java images read any KAFKA_* env as
  # Kafka client config (dots -> underscores), so mTLS is pure env + mounted p12s.
  local tlsenv="" tlsvol="" tlsmnt=""
  if [ "$tls" = 1 ]; then
    tlsenv="
        - { name: KAFKA_SECURITY_PROTOCOL,      value: SSL }
        - { name: KAFKA_SSL_TRUSTSTORE_TYPE,    value: PKCS12 }
        - { name: KAFKA_SSL_TRUSTSTORE_LOCATION, value: /certs/ca/ca.p12 }
        - { name: KAFKA_SSL_TRUSTSTORE_PASSWORD, valueFrom: { secretKeyRef: { name: my-cluster-cluster-ca-cert, key: ca.password } } }
        - { name: KAFKA_SSL_KEYSTORE_TYPE,      value: PKCS12 }
        - { name: KAFKA_SSL_KEYSTORE_LOCATION,  value: /certs/user/user.p12 }
        - { name: KAFKA_SSL_KEYSTORE_PASSWORD,  valueFrom: { secretKeyRef: { name: events-user, key: user.password } } }"
    tlsmnt="
        volumeMounts:
        - { name: ca,   mountPath: /certs/ca,   readOnly: true }
        - { name: user, mountPath: /certs/user, readOnly: true }"
    tlsvol="
      volumes:
      - { name: ca,   secret: { secretName: my-cluster-cluster-ca-cert, items: [{ key: ca.p12, path: ca.p12 }] } }
      - { name: user, secret: { secretName: events-user, items: [{ key: user.p12, path: user.p12 }] } }"
  fi

  oc apply -f - >/dev/null <<EV
apiVersion: apps/v1
kind: Deployment
metadata: { name: kafka-producer, namespace: $ns }
spec:
  replicas: 1
  selector: { matchLabels: { app: kafka-producer } }
  template:
    metadata: { labels: { app: kafka-producer } }
    spec:
      containers:
      - name: producer
        image: $EVENTS_PRODUCER_IMAGE
        env:
        - { name: KAFKA_BOOTSTRAP_SERVERS, value: "$BOOT" }
        - { name: KAFKA_KEY_SERIALIZER,    value: org.apache.kafka.common.serialization.StringSerializer }
        - { name: KAFKA_VALUE_SERIALIZER,  value: org.apache.kafka.common.serialization.StringSerializer }
        - { name: STRIMZI_TOPIC,           value: appsim-events }
        - { name: STRIMZI_DELAY_MS,        value: "500" }
        - { name: STRIMZI_MESSAGE_COUNT,   value: "1000000000" }
        - { name: STRIMZI_LOG_LEVEL,       value: INFO }$tlsenv$tlsmnt
        resources: { requests: { cpu: 50m, memory: 256Mi }, limits: { memory: 512Mi } }$tlsvol
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: kafka-streams, namespace: $ns }
spec:
  replicas: 1
  selector: { matchLabels: { app: kafka-streams } }
  template:
    metadata: { labels: { app: kafka-streams } }
    spec:
      containers:
      - name: streams
        image: $EVENTS_STREAMS_IMAGE
        env:
        - { name: KAFKA_BOOTSTRAP_SERVERS, value: "$BOOT" }
        - { name: KAFKA_APPLICATION_ID,    value: appsim-streams }
        - { name: STRIMZI_SOURCE_TOPIC,    value: appsim-events }
        - { name: STRIMZI_TARGET_TOPIC,    value: appsim-events-out }
        - { name: STRIMZI_LOG_LEVEL,       value: INFO }$tlsenv$tlsmnt
        resources: { requests: { cpu: 50m, memory: 384Mi }, limits: { memory: 768Mi } }$tlsvol
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: kafka-consumer, namespace: $ns }
spec:
  replicas: 1
  selector: { matchLabels: { app: kafka-consumer } }
  template:
    metadata: { labels: { app: kafka-consumer } }
    spec:
      containers:
      - name: consumer
        image: $EVENTS_CONSUMER_IMAGE
        env:
        - { name: KAFKA_BOOTSTRAP_SERVERS,   value: "$BOOT" }
        - { name: KAFKA_KEY_DESERIALIZER,    value: org.apache.kafka.common.serialization.StringDeserializer }
        - { name: KAFKA_VALUE_DESERIALIZER,  value: org.apache.kafka.common.serialization.StringDeserializer }
        - { name: STRIMZI_TOPIC,             value: appsim-events-out }
        - { name: KAFKA_GROUP_ID,            value: appsim-events-cg }
        - { name: STRIMZI_MESSAGE_COUNT,     value: "1000000000" }
        - { name: STRIMZI_LOG_LEVEL,         value: INFO }$tlsenv$tlsmnt
        resources: { requests: { cpu: 50m, memory: 256Mi }, limits: { memory: 512Mi } }$tlsvol
EV

  DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-events: producer->streams->consumer in ns $ns (backend: $backend$([ "$tls" = 1 ] && echo ', mTLS'))
                 watch: oc -n $ns logs deploy/kafka-consumer -f"
  return 0
}

# ── appsim-awx: Ansible automation (AWX project + job template, launched) ───
# Drives AWX through its REST API: creates an inventory + project (SCM) + job
# template and launches a job. Defaults to the well-known ansible-tower-samples
# repo (hello_world.yml) so it runs with no extra credentials; override
# AWX_PROJECT_REPO / AWX_PLAYBOOK to run a cluster-action playbook instead.
AWX_PROJECT_REPO=${AWX_PROJECT_REPO:-https://github.com/ansible/ansible-tower-samples}
AWX_PLAYBOOK=${AWX_PLAYBOOK:-hello_world.yml}

_awx_api() {  # _awx_api <method> <path> [json-body]
  if [ -n "${3:-}" ]; then
    curl -sk -u "admin:$AWX_PASS" -H 'Content-Type: application/json' -X "$1" "$AWX_API$2" -d "$3"
  else
    curl -sk -u "admin:$AWX_PASS" -X "$1" "$AWX_API$2"
  fi
}
_awx_id() {  # _awx_id <resource> <name>  -> existing id (or empty)
  _awx_api GET "/$1/?name=$(printf '%s' "$2" | sed 's/ /%20/g')" 2>/dev/null | jq -r '.results[0].id // empty'
}

install_appsim_awx() {
  log "AppSim/AWX: Ansible project + job template + launch (automation)"
  oc get ns awx >/dev/null 2>&1 && oc -n awx get awx awx >/dev/null 2>&1 || install_awx || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-awx   : FAILED — AWX unavailable"; return 1; }
  local host; host=$(oc -n awx get route awx -o jsonpath='{.spec.host}' 2>/dev/null)
  AWX_PASS=$(oc -n awx get secret awx-admin-password -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  [ -n "$host" ] && [ -n "$AWX_PASS" ] || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-awx   : FAILED — AWX route/admin password not found"; return 1; }
  AWX_API="https://$host/api/v2"

  echo "    waiting for the AWX API at https://$host"
  local t=0
  until [ "$(curl -sk -o /dev/null -w '%{http_code}' -u "admin:$AWX_PASS" "$AWX_API/ping/")" = 200 ]; do
    t=$((t+1)); [ $t -le 60 ] || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-awx   : FAILED — AWX API not reachable yet (try again later)"; return 1; }; sleep 5
  done

  local org inv proj jt
  org=$(_awx_api GET "/organizations/?name=Default" | jq -r '.results[0].id // 1')
  # inventory + localhost host (local connection)
  inv=$(_awx_id inventories "AppSim")
  [ -n "$inv" ] || inv=$(_awx_api POST /inventories/ "{\"name\":\"AppSim\",\"organization\":$org}" | jq -r '.id')
  if [ "$(_awx_api GET "/inventories/$inv/hosts/?name=localhost" | jq -r '.count')" = 0 ]; then
    _awx_api POST "/inventories/$inv/hosts/" \
      '{"name":"localhost","variables":"ansible_connection: local\nansible_python_interpreter: \"{{ ansible_playbook_python }}\""}' >/dev/null
  fi
  # project (SCM git) — AWX auto-syncs on create; wait for status successful
  proj=$(_awx_id projects "AppSim Samples")
  [ -n "$proj" ] || proj=$(_awx_api POST /projects/ \
    "{\"name\":\"AppSim Samples\",\"organization\":$org,\"scm_type\":\"git\",\"scm_url\":\"$AWX_PROJECT_REPO\",\"scm_update_on_launch\":false}" | jq -r '.id')
  echo "    syncing AWX project (id $proj)"
  t=0
  until [ "$(_awx_api GET "/projects/$proj/" | jq -r '.status')" = successful ]; do
    t=$((t+1)); [ $t -le 36 ] || { echo "    project still syncing — job template create may lag"; break; }; sleep 5
  done
  # job template
  jt=$(_awx_id job_templates "AppSim Hello")
  [ -n "$jt" ] || jt=$(_awx_api POST /job_templates/ \
    "{\"name\":\"AppSim Hello\",\"job_type\":\"run\",\"inventory\":$inv,\"project\":$proj,\"playbook\":\"$AWX_PLAYBOOK\"}" | jq -r '.id')
  # launch it and wait for the job to finish
  local job jobstatus=unknown
  job=$(_awx_api POST "/job_templates/$jt/launch/" "{}" | jq -r '.id // .job // empty')
  if [ -n "$job" ]; then
    echo "    launched job $job; waiting for it to finish"
    t=0
    while :; do
      jobstatus=$(_awx_api GET "/jobs/$job/" | jq -r '.status')
      case "$jobstatus" in successful|failed|error|canceled) break ;; esac
      t=$((t+1)); [ $t -le 36 ] || break; sleep 5
    done
  fi

  DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-awx   : https://$host  (admin / see secret awx-admin-password)
                 project 'AppSim Samples', job template 'AppSim Hello' launched -> $jobstatus
                 re-launch: Templates -> AppSim Hello -> Launch (or POST job_templates/$jt/launch/)"
  return 0
}

# ── appsim-cicd: full CI/CD GitOps loop (Jenkins -> Harbor -> GitLab -> ArgoCD) ──
# The closed loop a real team runs: Jenkins builds an image, pushes it to Harbor,
# bumps the image tag in a Helm chart stored in GitLab, and ArgoCD auto-syncs the
# new tag into the cluster. MOST COMPLEX / EXPERIMENTAL — many integration points.
#
# Mechanism choices (most reliable on OpenShift):
#  - image build: an OpenShift Docker-strategy BuildConfig that pushes to Harbor with
#    a robot pushSecret (no in-cluster Docker daemon / kaniko plumbing needed).
#  - Jenkins job: an OpenShift 'JenkinsPipeline' BuildConfig — the OpenShift-Sync
#    plugin in the Jenkins image auto-creates the Jenkins pipeline job from it, so we
#    avoid scripting the OAuth-protected Jenkins API. Drive it with `oc start-build`.
#  - GitLab: seed a project + token via the API (OAuth ROPC with the root password).
#  - ArgoCD: a repository credential secret + an Application watching the GitLab repo.
APPSIM_CICD_APP_TAG=${APPSIM_CICD_APP_TAG:-v1}

_gitlab_token() {  # echo an API token for root via OAuth resource-owner password grant
  local gl=$1 pw=$2
  curl -sk -X POST "$gl/oauth/token" \
    -d "grant_type=password&username=root&password=$pw" 2>/dev/null \
    | jq -r '.access_token // empty'
}
_glapi() { curl -sk -H "Authorization: Bearer $GL_TOKEN" -H 'Content-Type: application/json' "$@"; }

install_appsim_cicd() {
  # CI engine: jenkins (default, OpenShift JenkinsPipeline) or gitlab (GitLab CI).
  # The CD half (ArgoCD GitOps) is identical either way.
  local ci=${APPSIM_CICD_CI:-jenkins}
  log "AppSim/CI-CD: $ci -> Harbor -> GitLab -> ArgoCD GitOps loop — EXPERIMENTAL"
  local ns=appsim-cicd ingd; ingd=$(_ingress_domain)
  # ── prerequisites ──
  _appsim_need_argocd || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-cicd  : FAILED — ArgoCD unavailable"; return 1; }
  [ "$ci" = gitlab ] || oc -n jenkins get deploy jenkins >/dev/null 2>&1 || install_jenkins || true
  oc get ns harbor >/dev/null 2>&1 || install_harbor || true
  # GitLab is heavy + async — if it isn't up yet, kick it off and ask to re-run
  if ! oc -n gitlab-system get gitlab gitlab >/dev/null 2>&1; then
    install_gitlab || true
    DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-cicd  : GitLab is installing (async, slow). Re-run --devops-components appsim-cicd
                 once 'oc -n gitlab-system get pods' is all Running."
    return 0
  fi
  # GitLab ships its OWN bundled nginx-ingress (a LoadBalancer with no external IP
  # on platform 'none') instead of an OpenShift Route, so it isn't reachable at
  # *.apps. Add an edge Route to the webservice/workhorse (8181 serves UI+API+git)
  # so both this host and in-cluster ArgoCD/Jenkins can reach it at gitlab.<apps>.
  local glpw; glpw=$(oc -n gitlab-system get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  [ -n "$glpw" ] || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-cicd  : FAILED — GitLab root password secret not found; re-run later"; return 1; }
  _make_route gitlab-system gitlab-ext gitlab-webservice-default http-workhorse "gitlab.$ingd"
  local GL="https://gitlab.$ingd"
  echo "    waiting for GitLab to answer at $GL"
  local t=0
  until [ "$(curl -sk -o /dev/null -w '%{http_code}' "$GL/-/health")" = 200 ]; do
    t=$((t+1)); [ $t -le 60 ] || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-cicd  : FAILED — GitLab not reachable at $GL yet; re-run once its pods are all Running"; return 1; }; sleep 5
  done
  GL_TOKEN=$(_gitlab_token "$GL" "$glpw")
  [ -n "$GL_TOKEN" ] || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-cicd  : FAILED — could not get a GitLab API token (OAuth password grant);
                 create a root PAT manually and re-run"; return 1; }

  _devops_ns "$ns"
  oc adm policy add-scc-to-group anyuid system:serviceaccounts:"$ns" >/dev/null 2>&1 || true
  local harbor_host="harbor.$ingd" image="harbor.$ingd/appsim/app"

  # ── 1) GitLab project 'appsim/app-config' seeded with a Helm chart + values ──
  _glapi -X POST "$GL/api/v4/projects" \
    -d '{"name":"app-config","path":"app-config","visibility":"internal","initialize_with_readme":true}' >/dev/null 2>&1 || true
  local proj; proj=$(_glapi "$GL/api/v4/projects?search=app-config" | jq -r '.[0].id // empty')
  if [ -n "$proj" ]; then
    # commit a file (create, or update if it already exists). $1=url-encoded path, $2=content
    _glcommit() {
      local body; body=$(jq -n --arg c "$2" '{branch:"main",content:$c,commit_message:"seed"}')
      _glapi -X POST "$GL/api/v4/projects/$proj/repository/files/$1" -d "$body" >/dev/null 2>&1 \
        || _glapi -X PUT "$GL/api/v4/projects/$proj/repository/files/$1" -d "$body" >/dev/null 2>&1
    }
    _glcommit "Chart%2Eyaml" "$(printf 'apiVersion: v2\nname: appsim-app\nversion: 0.1.0\n')"
    _glcommit "values%2Eyaml" "$(printf 'image:\n  repository: %s\n  tag: %s\n' "$image" "$APPSIM_CICD_APP_TAG")"
    _glcommit "templates%2Fdeploy%2Eyaml" "$(cat <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: app }
spec:
  replicas: 1
  selector: { matchLabels: { app: appsim-app } }
  template:
    metadata: { labels: { app: appsim-app } }
    spec:
      containers:
      - name: app
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        ports: [{ containerPort: 8080 }]
YAML
)"
  fi
  local repoURL="$GL/root/app-config.git"

  # ── 2) Harbor project 'appsim' + robot account (push creds) ──
  local hpw; hpw=$(oc -n harbor get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
  curl -sk -u "admin:$hpw" -X POST "https://$harbor_host/api/v2.0/projects" \
    -H 'Content-Type: application/json' -d '{"project_name":"appsim","public":true}' >/dev/null 2>&1 || true
  local robot; robot=$(curl -sk -u "admin:$hpw" -X POST "https://$harbor_host/api/v2.0/robots" \
    -H 'Content-Type: application/json' \
    -d '{"name":"appsim-ci","duration":-1,"level":"system","permissions":[{"kind":"project","namespace":"appsim","access":[{"resource":"repository","action":"push"},{"resource":"repository","action":"pull"}]}]}' 2>/dev/null)
  local rname rsecret; rname=$(echo "$robot" | jq -r '.name // empty'); rsecret=$(echo "$robot" | jq -r '.secret // empty')
  if [ -n "$rsecret" ]; then
    oc -n "$ns" create secret docker-registry harbor-push \
      --docker-server="$harbor_host" --docker-username="$rname" --docker-password="$rsecret" \
      --dry-run=client -o yaml | oc apply -f - >/dev/null
  fi
  # auto-scan images pushed to 'appsim' (Trivy, report-only) — _harbor_autoscan is in devops.sh
  _harbor_autoscan appsim "$harbor_host" "$hpw" >/dev/null 2>&1 \
    && echo "    Harbor scan-on-push (Trivy) enabled for project 'appsim'"

  # ── 2b) SonarQube (optional): if it's installed, provision a project + CI token
  #        and a 'sonar-ci' secret the pipeline's analysis stage consumes. ──
  if oc get ns sonarqube >/dev/null 2>&1 && oc -n sonarqube get route sonarqube >/dev/null 2>&1; then
    local sqhost token; sqhost=$(oc -n sonarqube get route sonarqube -o jsonpath='{.spec.host}' 2>/dev/null)
    curl -sk -u admin:admin -X POST "https://$sqhost/api/projects/create?project=appsim&name=appsim" >/dev/null 2>&1 || true
    token=$(curl -sk -u admin:admin -X POST "https://$sqhost/api/user_tokens/generate?name=appsim-ci-$RANDOM" 2>/dev/null | jq -r '.token // empty')
    if [ -n "$token" ]; then
      oc -n "$ns" create secret generic sonar-ci \
        --from-literal=SONAR_HOST_URL="http://sonarqube-sonarqube.sonarqube.svc:9000" \
        --from-literal=SONAR_TOKEN="$token" --dry-run=client -o yaml | oc apply -f - >/dev/null
      echo "    SonarQube project 'appsim' + CI token provisioned (sonar-ci secret)"
    else
      echo "    SonarQube present but token provisioning failed (admin pw changed?) — analysis stage will skip"
    fi
  else
    echo "    SonarQube not installed — pipeline's analysis stage will skip (install with --devops-components sonarqube)"
  fi

  # Trust Harbor's self-signed route so the kubelet can PULL the built image
  # (CRI-O rejects the router cert otherwise -> ImagePullBackOff x509). This edits
  # the cluster image config and, the FIRST time only, triggers a MachineConfig
  # rollout (nodes drain+reboot, ~10-15 min). Idempotent: skips if already set.
  if ! oc get image.config.openshift.io/cluster -o jsonpath='{.spec.registrySources.insecureRegistries}' 2>/dev/null | grep -q "$harbor_host"; then
    echo "    adding $harbor_host to cluster insecureRegistries (one-time node rollout/reboot)"
    oc get image.config.openshift.io/cluster -o json 2>/dev/null \
      | jq --arg h "$harbor_host" '.spec.registrySources.insecureRegistries = ((.spec.registrySources.insecureRegistries // []) + [$h] | unique)' \
      | oc apply -f - >/dev/null 2>&1 || true
  fi

  # ── 3) CI engine ──
  if [ "$ci" = gitlab ]; then
    # GitLab CI: a Kubernetes-executor runner + a .gitlab-ci.yml in the repo replace
    # the Jenkins pipeline. Same stages (sonar -> kaniko build/push -> bump tag);
    # ArgoCD CD is unchanged.
    local rtok; rtok=$(_glapi -X POST "$GL/api/v4/user/runners" \
      -d 'runner_type=instance_type&description=appsim-cicd&tag_list=appsim,kubernetes' 2>/dev/null | jq -r '.token // empty')
    if [ -n "$rtok" ]; then
      install_gitlab_runner "$GL" "$rtok" || true
    else
      echo "    could not create a GitLab runner token via the API (admin?) — register a runner manually"
    fi
    # project CI/CD variables the pipeline uses (Harbor robot, SonarQube, image, push token)
    local hpush_user hpush_pass
    hpush_user=$(oc -n "$ns" get secret harbor-push -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null | jq -r '.auths[].auth' | base64 -d 2>/dev/null | cut -d: -f1)
    hpush_pass=$(oc -n "$ns" get secret harbor-push -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null | jq -r '.auths[].auth' | base64 -d 2>/dev/null | cut -d: -f2-)
    _glvar() { _glapi -X POST "$GL/api/v4/projects/$proj/variables" -d "key=$1&value=$2&masked=false&protected=false" >/dev/null 2>&1 \
      || _glapi -X PUT "$GL/api/v4/projects/$proj/variables/$1" -d "value=$2" >/dev/null 2>&1; }
    _glvar HARBOR_HOST "$harbor_host"
    _glvar HARBOR_USER "$hpush_user"
    _glvar HARBOR_PASS "$hpush_pass"
    _glvar IMAGE "$image"
    _glvar GL_PUSH_TOKEN "$GL_TOKEN"
    [ -n "${SONAR_HOST_URL:-}" ] && { _glvar SONAR_HOST_URL "$SONAR_HOST_URL"; _glvar SONAR_TOKEN "${SONAR_TOKEN:-}"; }
    # seed .gitlab-ci.yml (kaniko build + sonar + tag bump). $$ pipeline IID = tag.
    _glcommit ".gitlab-ci%2Eyml" "$(cat <<'GLCI'
stages: [scan, build, deploy]
variables:
  TAG: "v${CI_PIPELINE_IID}"
sonarqube:
  stage: scan
  image: sonarsource/sonar-scanner-cli:latest
  script:
    - if [ -n "$SONAR_HOST_URL" ]; then sonar-scanner -Dsonar.projectKey=appsim -Dsonar.sources=. -Dsonar.host.url=$SONAR_HOST_URL -Dsonar.token=$SONAR_TOKEN || true; else echo "SonarQube not configured, skipping"; fi
  allow_failure: true
build:
  stage: build
  image:
    name: gcr.io/kaniko-project/executor:debug
    entrypoint: [""]
  script:
    - mkdir -p /kaniko/.docker
    - echo "{\"auths\":{\"$HARBOR_HOST\":{\"auth\":\"$(printf '%s:%s' "$HARBOR_USER" "$HARBOR_PASS" | base64 | tr -d '\n')\"}}}" > /kaniko/.docker/config.json
    - echo -e "FROM ghcr.io/stefanprodan/podinfo:latest\nLABEL appsim=cicd" > Dockerfile
    - /kaniko/executor --dockerfile=Dockerfile --context=. --destination=$IMAGE:$TAG --skip-tls-verify
deploy:
  stage: deploy
  image: alpine/git:latest
  variables: { GIT_SSL_NO_VERIFY: "true" }
  script:
    - git clone https://oauth2:${GL_PUSH_TOKEN}@${CI_SERVER_HOST}/root/app-config.git cfg
    - cd cfg
    - sed -i "s|  tag:.*|  tag: ${TAG}|" values.yaml
    - git -c user.email=ci@appsim -c user.name=ci commit -am "ci: image ${TAG}" || true
    - git push origin HEAD:main || true
GLCI
)"
    echo "    GitLab CI configured: runner + .gitlab-ci.yml seeded (pipeline runs on push)"
  else
  # ── Jenkins engine: kaniko (no internal registry on platform 'none' -> daemonless
  #    build) + a JenkinsPipeline BuildConfig. Ship a Dockerfile + kaniko Job template. ──
  oc -n "$ns" create configmap appsim-dockerfile \
    --from-literal=Dockerfile=$'FROM ghcr.io/stefanprodan/podinfo:latest\nLABEL appsim=cicd' \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc -n "$ns" create configmap kaniko-job --dry-run=client -o yaml --from-file=job.yaml=/dev/stdin <<KJOB | oc apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: kaniko-build, namespace: $ns }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: kaniko
        image: gcr.io/kaniko-project/executor:latest
        args:
        - --dockerfile=/wt/Dockerfile
        - --context=dir:///wt
        - --destination=$image:__TAG__
        - --skip-tls-verify
        - --skip-tls-verify-pull
        volumeMounts:
        - { name: dockerfile, mountPath: /wt }
        - { name: dockercfg, mountPath: /kaniko/.docker }
      volumes:
      - { name: dockerfile, configMap: { name: appsim-dockerfile } }
      - name: dockercfg
        secret: { secretName: harbor-push, items: [{ key: .dockerconfigjson, path: config.json }] }
KJOB

  # SonarQube analysis Job template (used only when the 'sonar-ci' secret exists):
  # an initContainer clones the config repo, then sonar-scanner-cli submits analysis.
  oc -n "$ns" create configmap sonar-job --dry-run=client -o yaml --from-file=job.yaml=/dev/stdin <<SJOB | oc apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: sonar-scan, namespace: $ns }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      initContainers:
      - name: clone
        image: alpine/git:latest
        env: [{ name: GIT_SSL_NO_VERIFY, value: "true" }]
        args: ["clone", "https://oauth2:$GL_TOKEN@gitlab.$ingd/root/app-config.git", "/src"]
        volumeMounts: [{ name: src, mountPath: /src }]
      containers:
      - name: scanner
        image: sonarsource/sonar-scanner-cli:latest
        workingDir: /src
        args: ["-Dsonar.projectKey=appsim", "-Dsonar.sources=/src"]
        envFrom: [{ secretRef: { name: sonar-ci } }]
        volumeMounts: [{ name: src, mountPath: /src }]
      volumes: [{ name: src, emptyDir: {} }]
SJOB

  # Jenkins pipeline (OpenShift-Sync turns this BuildConfig into a Jenkins job).
  # MUST live in the 'jenkins' namespace — the OpenShift Jenkins sync plugin only
  # watches Jenkins' own namespace. Runs on the Jenkins controller (has oc + the
  # jenkins SA, granted edit in $ns): renders the kaniko Job for this build's tag,
  # waits for it, then bumps the GitLab tag (all targeting $ns cross-namespace).
  oc apply -f - >/dev/null <<BC
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata: { name: appsim-pipeline, namespace: jenkins }
spec:
  strategy:
    type: JenkinsPipeline
    jenkinsPipelineStrategy:
      jenkinsfile: |
        pipeline {
          agent any
          environment { TAG = "v\${BUILD_NUMBER}" }
          stages {
            stage('SonarQube analysis (SAST)') {
              steps {
                sh '''
                  if oc -n $ns get secret sonar-ci >/dev/null 2>&1; then
                    oc -n $ns delete job sonar-scan --ignore-not-found
                    oc -n $ns get cm sonar-job -o go-template='{{index .data "job.yaml"}}' | oc -n $ns apply -f -
                    oc -n $ns wait --for=condition=complete job/sonar-scan --timeout=300s || echo "sonar-scan did not complete (non-fatal)"
                    oc -n $ns logs job/sonar-scan --tail=5 || true
                  else
                    echo "SonarQube not provisioned (no sonar-ci secret) — skipping code analysis"
                  fi
                '''
              }
            }
            stage('build & push image (kaniko)') {
              steps {
                sh '''
                  oc -n $ns delete job kaniko-build --ignore-not-found
                  oc -n $ns get cm kaniko-job -o go-template='{{index .data "job.yaml"}}' | sed "s|__TAG__|\$TAG|g" | oc -n $ns apply -f -
                  oc -n $ns wait --for=condition=complete job/kaniko-build --timeout=400s
                '''
              }
            }
            stage('image scan report (Trivy via Harbor)') {
              steps {
                sh '''
                  A="https://$harbor_host/api/v2.0/projects/appsim/repositories/app/artifacts/\$TAG"
                  curl -sk -u "admin:$hpw" -X POST "\$A/scan" >/dev/null 2>&1 || true
                  echo "waiting for Trivy scan..."; sleep 45
                  echo "Trivy scan summary for $image:\$TAG :"
                  curl -sk -u "admin:$hpw" "\$A?with_scan_overview=true" | tr "," "\\n" | grep -iE "scan_status|severity|total|fixable|Critical|High|Medium|Low" | head -15
                  echo "(report-only - build not gated)"
                '''
              }
            }
            stage('bump GitOps tag') {
              steps {
                sh '''
                  git config --global http.sslVerify false
                  rm -rf cfg
                  git clone https://oauth2:$GL_TOKEN@gitlab.$ingd/root/app-config.git cfg
                  cd cfg
                  sed -i "s|  tag:.*|  tag: \$TAG|" values.yaml
                  git -c user.email=ci@appsim -c user.name=ci commit -am "ci: image \$TAG" || true
                  git push origin HEAD:main || true
                '''
              }
            }
          }
        }
BC
  fi

  # ── 4) ArgoCD repo credential + Application watching the GitLab chart ──
  oc apply -f - >/dev/null <<RC
apiVersion: v1
kind: Secret
metadata:
  name: appsim-cicd-repo
  namespace: argocd
  labels: { argocd.argoproj.io/secret-type: repository }
stringData:
  type: git
  url: $repoURL
  username: root
  password: $GL_TOKEN
  insecure: "true"
RC
  # the Jenkins SA (ns jenkins) drives `oc start-build` in this ns -> needs edit here
  [ "$ci" = gitlab ] || oc adm policy add-role-to-user edit system:serviceaccount:jenkins:jenkins -n "$ns" >/dev/null 2>&1 || true
  _argocd_app appsim-cicd "$ns" "$repoURL" . main

  local trigger="oc -n jenkins start-build appsim-pipeline"
  [ "$ci" = gitlab ] && trigger="push to GitLab $repoURL (GitLab CI runs .gitlab-ci.yml)"
  DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-cicd  : loop wired (EXPERIMENTAL, CI engine: $ci). GitLab repo $repoURL,
                 Harbor project 'appsim', ArgoCD app 'appsim-cicd'.
                 Trigger a run: $trigger
                 -> new image tag in Harbor -> commit in GitLab -> ArgoCD syncs ns $ns"
  return 0
}

# ── appsim-mesh: Online Boutique inside an Istio mesh (for Kiali/Jaeger) ───
install_appsim_mesh() {
  log "AppSim/Mesh: Online Boutique in an Istio mesh, observed by Kiali/Jaeger — heavy/EXPERIMENTAL"
  oc -n istio-system get deploy istiod >/dev/null 2>&1 || install_istio || true
  oc -n istio-system get deploy kiali  >/dev/null 2>&1 || install_kiali || true
  _appsim_need_argocd || { DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-mesh : FAILED — ArgoCD unavailable"; return 1; }
  local ns=appsim-mesh ingd; ingd=$(_ingress_domain)
  _devops_ns "$ns"
  # sidecar injection + anyuid for the Boutique containers and the Envoy sidecars
  oc label ns "$ns" istio-injection=enabled --overwrite >/dev/null 2>&1 || true
  oc adm policy add-scc-to-group anyuid system:serviceaccounts:"$ns" >/dev/null 2>&1 || true
  _argocd_app boutique-mesh "$ns" "$BOUTIQUE_REPO" helm-chart main
  local t=0
  until oc -n "$ns" get svc frontend >/dev/null 2>&1; do
    t=$((t+1)); [ $t -le 48 ] || { echo "    frontend Service not synced yet — check: oc -n argocd get app boutique-mesh"; break; }; sleep 5
  done
  [ -n "$ingd" ] && oc -n "$ns" get svc frontend >/dev/null 2>&1 && _make_route "$ns" boutique-mesh frontend http "boutique-mesh.$ingd"
  DEVOPS_NOTE="$DEVOPS_NOTE
  appsim-mesh : Online Boutique in Istio (ns $ns, istio-injection=enabled; pods should be 2/2).
                Live service graph in Kiali (https://kiali.$ingd), traces in Jaeger
                (https://jaeger.$ingd), store https://boutique-mesh.$ingd. Locust drives traffic."
  return 0
}
