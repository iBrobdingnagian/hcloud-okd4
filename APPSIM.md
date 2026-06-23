# Application Simulations

Real-world deployment scenarios that exercise the DevOps stack this repo installs
(ArgoCD, Jenkins, Harbor, JFrog, AWX, Kafka/ZooKeeper, Strimzi) the way a real team
would — GitOps, a full CI/CD loop, a multi-service app under load, an event-driven
pipeline, and automation. They live in `functions/appsim.sh` and are selectable from
the DevOps menu (`./deploy-okd.sh --devops`) or with `--devops-components`.

Each installer is **best-effort** and **self-bootstrapping**: if its prerequisite tool
isn't installed it calls the matching `install_*` (e.g. `install_argocd`,
`install_strimzi`, `install_gitlab`) first, exactly like the original `install_appsim`.

> These build on the **observability** stack (`OBSERVABILITY` / `--monitoring`): point
> Grafana at the namespaces below, or use the OpenShift console, to watch them run.

---

## The scenarios

| # (menu) | Token | What it deploys | Sample app | Weight |
|---|---|---|---|---|
| 16 | `appsim-gitops`   | ArgoCD deploys a Helm chart from Git + a traffic generator | [podinfo](https://github.com/stefanprodan/podinfo) | light |
| 17 | `appsim-boutique` | ArgoCD deploys an 11-service store with a built-in load generator | [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) | heavy |
| 18 | `appsim-events`   | Kafka pipeline: producer → Streams → consumer | [strimzi/client-examples](https://github.com/strimzi/client-examples) | medium |
| 19 | `appsim-awx`      | AWX project + job template, launched (Ansible automation) | ansible-tower-samples | light |
| 20 | `appsim-cicd`     | Full CI/CD GitOps loop (see below) | kaniko-built podinfo | heavy |
| 21 | `appsim-all`      | `appsim-gitops` + `appsim-events` + `appsim-awx` (the light subset) | — | medium |

The original Kafka traffic demo is still there as `appsim` (menu 11).

### Running them

```bash
# interactive menu
./deploy-okd.sh --devops          # pick 16-21 from the list

# non-interactive (comma list)
./deploy-okd.sh --devops-components appsim-gitops,appsim-events,appsim-awx
./deploy-okd.sh --devops-components appsim-cicd        # full loop (also brings up GitLab)
```

Common env overrides: `APPSIM_BACKEND=kafka|strimzi` (events), `PODINFO_REPO`,
`BOUTIQUE_REPO`, `EVENTS_{PRODUCER,CONSUMER,STREAMS}_IMAGE`,
`AWX_PROJECT_REPO`/`AWX_PLAYBOOK`, `APPSIM_CICD_APP_TAG`, `GITLAB_CHART_VERSION`.

---

## 1. GitOps — `appsim-gitops`  (ns `appsim-gitops`)

ArgoCD `Application` **podinfo** that renders the Helm chart straight from
`github.com/stefanprodan/podinfo` (path `charts/podinfo`, no version pin) with
automated sync + self-heal, plus a curl **traffic generator** hammering podinfo's
endpoints and an edge Route.

```bash
oc -n argocd get app podinfo                      # Synced / Healthy
oc -n appsim-gitops get pods                       # podinfo + traffic-gen Running
curl -k https://podinfo.apps.<domain>/api/info     # 200, podinfo JSON
```

The destination namespace is labelled `argocd.argoproj.io/managed-by=argocd` so the
operator grants the application-controller RBAC there (all ArgoCD apps here do this).

## 2. Online Boutique — `appsim-boutique`  (ns `appsim-boutique`)  [heavy]

ArgoCD deploys GoogleCloud's microservices-demo Helm chart (`helm-chart`, ~11
services). Its **built-in Locust load generator** drives realistic user traffic — no
extra generator needed. `anyuid` is granted (some containers want fixed uids).

```bash
oc -n appsim-boutique get pods                     # ~12 Running
oc -n appsim-boutique logs deploy/loadgenerator    # RPS / aggregated requests
curl -k https://boutique.apps.<domain>/            # storefront, 200
```

## 3. Events — `appsim-events`  (ns `appsim-events`)

A real Kafka **event pipeline** using Strimzi's Java client images:
`producer → topic appsim-events → Kafka Streams (reverses the value) → topic
appsim-events-out → consumer`. Backend is selectable:

- **classic** (`APPSIM_BACKEND=kafka`, default) — plaintext to `kafka.kafka.svc:9092`.
- **strimzi** (`APPSIM_BACKEND=strimzi`) — mTLS to `my-cluster-kafka-bootstrap.strimzi:9093`
  using a dedicated `events-user` (TLS auth, ACLs over the `appsim` prefix); the
  cluster CA + user cert are copied into the app namespace.

```bash
oc -n appsim-events logs deploy/kafka-consumer -f  # e.g. value: "841-dlrow olleH"
```

## 4. AWX — `appsim-awx`  (ns `awx`)

Drives the **AWX REST API** to create an inventory (localhost), a project (SCM git,
defaults to `ansible-tower-samples`), and a job template, then **launches a job** and
waits for it to finish. Override `AWX_PROJECT_REPO`/`AWX_PLAYBOOK` to run a
cluster-action playbook (e.g. `kubernetes.core` to scale a workload).

```bash
# URL + admin password
oc -n awx get route awx -o jsonpath='{.spec.host}{"\n"}'
oc -n awx get secret awx-admin-password -o jsonpath='{.data.password}' | base64 -d
# job template "AppSim Hello" should be 'successful'; re-launch from Templates -> Launch
```

## 5. CI/CD loop — `appsim-cicd`  (ns `appsim-cicd`, pipeline in `jenkins`)  [heavy]

The closed loop a real team runs:

```
SonarQube (code scan) ─▶ Jenkins ─(kaniko build)→ Harbor ─(Trivy image scan)→ ┐
        └─(git tag bump)→ GitLab ─(values.yaml)→ ArgoCD ─(sync)→ app pod
```

The pipeline includes a **SonarQube analysis** stage (if SonarQube is installed) and a
**Trivy image-scan report** after the push — both report-only (they log results, don't
fail the build). See **[SCANNING.md](SCANNING.md)** for image-vs-code scanning details.

What the installer wires up:
- **GitLab** repo `root/app-config` seeded with a tiny Helm chart whose `values.yaml`
  carries `image.tag` (the thing CI bumps). GitLab is reached via an OpenShift edge
  Route to its workhorse; an OAuth token is minted from the root password.
- **Harbor** project `appsim` + a robot push account (stored as `harbor-push`).
- A **kaniko** Dockerfile + Job template (configmap) — daemonless image build.
- A **JenkinsPipeline** BuildConfig (`appsim-pipeline`, in the `jenkins` namespace):
  renders the kaniko Job for the build's tag, waits for it, then commits the new tag
  to GitLab.
- An **ArgoCD** repo credential + `Application` (`appsim-cicd`) watching the GitLab repo.

Trigger a run and watch the loop:

```bash
oc -n jenkins start-build appsim-pipeline
# image lands in Harbor:
#   curl -ksu admin:<harbor-pw> https://harbor.apps.<domain>/api/v2.0/projects/appsim/repositories/app/artifacts
# tag bumped in GitLab values.yaml, then:
oc -n argocd get app appsim-cicd                   # Synced / Healthy
oc -n appsim-cicd get pods -l app=appsim-app        # Running from the Harbor image
```

---

## Platform-"none" specifics (why this works here)

OKD on Hetzner is platform `none` (UPI), which changes a few things the CI/CD loop has
to account for — all handled automatically:

- **No internal image registry** (it's `Removed`, no storage) → no OpenShift Docker
  builds; images are built with **kaniko** and pushed straight to Harbor.
- **Harbor uses a self-signed router cert** → the loop adds Harbor's route to
  `image.config.openshift.io/cluster` `insecureRegistries` so the kubelet can pull.
  ⚠️ **This triggers a one-time MachineConfig rollout — every node drains and reboots
  (~10–15 min).** It only happens the first time (idempotent thereafter).
- **GitLab** ships its own nginx-ingress (a `LoadBalancer` with no external IP here),
  so the loop creates an OpenShift edge Route to reach it.
- **GitLab operator** requires `spec.chart.version` (else "invalid version format");
  defaulted to a version the N-2-pinned operator supports (`GITLAB_CHART_VERSION`).
- **Jenkins** runs the OpenShift Jenkins image; its sync plugin only watches its own
  namespace, so the pipeline BuildConfig lives in `jenkins`.

## Cleanup

```bash
# ArgoCD apps (deleting the Application prunes its workloads when cascade is on)
oc -n argocd delete app podinfo boutique appsim-cicd
# namespaces
oc delete ns appsim-gitops appsim-boutique appsim-events appsim-cicd
# the insecureRegistries entry persists (and would reboot nodes again to remove) —
# leave it unless you specifically need to revert: oc edit image.config.openshift.io/cluster
```
