# CI/CD engines for `appsim-cicd` — Jenkins vs GitLab CI

The `appsim-cicd` simulation ([APPSIM.md](APPSIM.md)) runs a full **CI/CD GitOps loop**.
The **CD** half is always **ArgoCD** (GitOps); only the **CI** engine is swappable:

```bash
# Jenkins (default)
./deploy-okd.sh --devops-components appsim-cicd
# GitLab CI
APPSIM_CICD_CI=gitlab ./deploy-okd.sh --devops-components appsim-cicd
```

Both engines do the same work and end in the same place:

```
 (CI engine) ── SonarQube scan ─ kaniko build ─ push to Harbor (Trivy scan) ─ bump image tag in GitLab
                                                                                      │
                                                              ArgoCD (CD) ── sync ────┘──▶ running pod
```

Everything *except the CI engine* is shared by both paths: the **GitLab** `app-config`
repo (the GitOps source of truth), the **Harbor** project + robot push account, the
**SonarQube** project/token, the **insecure-registry** trust, and the **ArgoCD**
`Application`.

## What Jenkins does (default engine)

`install_appsim_cicd` creates a **JenkinsPipeline `BuildConfig`** in the `jenkins`
namespace. The OpenShift Jenkins **sync plugin** turns it into a Jenkins pipeline job
(no GitLab runner needed). Stages:

1. **SonarQube analysis** — a `sonar-scanner-cli` Job (SAST).
2. **build & push** — a **kaniko** Job builds the image and pushes to Harbor
   (Trivy scans it on push).
3. **image scan report** — logs the Harbor/Trivy CVE summary (report-only).
4. **bump GitOps tag** — edits `values.yaml` in the GitLab repo and commits.

Trigger: `oc -n jenkins start-build appsim-pipeline`.

Why this works well on OpenShift: it's the OpenShift-native integration (BuildConfig +
sync plugin), so there's no extra runner to register, and the pipeline runs as the
Jenkins SA with cross-namespace rights.

## What GitLab CI does (alternative engine)

With `APPSIM_CICD_CI=gitlab`, `install_appsim_cicd` instead:

1. Creates a **GitLab Runner** (`install_gitlab_runner`, Helm, **Kubernetes executor**)
   registered to the in-cluster GitLab with a runner token minted via the GitLab API.
2. Sets the project **CI/CD variables** (`HARBOR_HOST/USER/PASS`, `IMAGE`,
   `SONAR_HOST_URL/TOKEN`, `GL_PUSH_TOKEN`) via the GitLab API.
3. Seeds a **`.gitlab-ci.yml`** into the `app-config` repo with the equivalent stages:
   - `scan` — `sonarsource/sonar-scanner-cli`
   - `build` — `gcr.io/kaniko-project/executor` builds & pushes to Harbor (`--skip-tls-verify`)
   - `deploy` — `alpine/git` bumps the tag in `values.yaml` and pushes

Trigger: **push to the GitLab repo** (the pipeline runs automatically on the runner).
ArgoCD then syncs exactly as in the Jenkins path.

## Choosing

| | Jenkins (default) | GitLab CI |
|---|---|---|
| Runner needed | no (sync plugin) | yes (GitLab Runner, k8s executor) |
| Pipeline definition | JenkinsPipeline BuildConfig | `.gitlab-ci.yml` in the repo |
| Trigger | `oc start-build` | git push |
| Best when | you want the OpenShift-native path | you already standardize on GitLab |

Both are EXPERIMENTAL and best-effort; the CD half (ArgoCD) and the registry/scanning
integrations are identical, so you can switch engines without changing how deployments happen.
