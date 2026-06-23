# Security Scanning — images (Harbor/Trivy) + code (SonarQube)

Two scanners cover two **different layers**. They are complementary, not
interchangeable:

| Tool | Scans | Layer | When | Finds |
|------|-------|-------|------|-------|
| **Harbor + Trivy** | container **images** | the built artifact | on push / on demand | CVEs in OS packages & libraries |
| **SonarQube** | **source code** | before the build | in CI | bugs, code smells, security hotspots, coverage |

> SonarQube does **not** scan images, and Harbor does **not** scan source. A real
> pipeline runs SonarQube on the code *and* lets Harbor/Trivy scan the resulting image.

---

## Harbor / Trivy — image vulnerability scanning

Harbor ships **Trivy** as its default scanner (pod `harbor-trivy-0` in the `harbor`
namespace). The deploy enables **scan-on-push** so every image pushed to Harbor is
scanned automatically — no manual step.

### How it's wired
- `_harbor_autoscan <project>` (`functions/devops.sh`) sets the project metadata
  `auto_scan: "true"` via the Harbor API.
- `install_harbor` calls it for the default **library** project; `install_appsim_cicd`
  calls it for the **appsim** project. Re-runnable / idempotent.

### Use it

```bash
HOST=harbor.apps.<domain>
PW=$(oc -n harbor get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)

# scan on demand
curl -ksu admin:$PW -X POST "https://$HOST/api/v2.0/projects/appsim/repositories/app/artifacts/v1/scan"

# read the CVE summary
curl -ksu admin:$PW "https://$HOST/api/v2.0/projects/appsim/repositories/app/artifacts/v1?with_scan_overview=true" \
  | jq '.scan_overview[].summary'        # {"total":30,"fixable":30,"summary":{"High":2,"Medium":8,"Low":20}}
```

In the UI: **Projects → <project> → Repositories → <repo> → tag → Vulnerabilities**.

### Report-only vs blocking
The deploy enables **scan-on-push (report-only)** — images are scanned and results are
visible, but nothing is blocked. To **enforce** a quality gate later (prevent pulling /
deploying images above a severity), set the project's deployment-security policy:

```bash
curl -ksu admin:$PW -X PUT "https://$HOST/api/v2.0/projects/appsim" -H 'Content-Type: application/json' \
  -d '{"metadata":{"auto_scan":"true","prevent_vul":"true","severity":"high"}}'
```

---

## SonarQube — source-code (SAST) scanning

Install it as a DevOps component (official SonarSource Helm chart, community edition):

```bash
./deploy-okd.sh --devops-components sonarqube
# or pick "SonarQube" from ./deploy-okd.sh --devops
```

- Namespace `sonarqube`; bundled PostgreSQL; URL `https://sonarqube.apps.<domain>`
  (default login **admin / admin** — change it on first login).
- **Heavy / EXPERIMENTAL**: its Elasticsearch needs `vm.max_map_count=524288`, set by the
  chart's privileged `initSysctl` init container (the namespace SAs are granted the
  `privileged` SCC). Budget ~2–3 GB RAM; it is slow to start.

### In the CI loop (`appsim-cicd`)
When SonarQube is installed, `install_appsim_cicd` provisions a project (`appsim`) and a
CI token (`sonar-ci` secret), and the Jenkins pipeline runs a **SonarQube analysis**
stage (`sonar-scanner-cli`) before the build. If SonarQube isn't installed the stage
logs a skip and the build proceeds.

> ⚠️ The `appsim-cicd` demo app is built *from* the podinfo image (no compiled source),
> so the analysis stage scans the config repo — it proves the wiring. Point it at a real
> source repo (`sonar.sources`) for meaningful SAST results.

---

## The CI/CD pipeline with scanning (`appsim-cicd`)

```
SonarQube analysis (code) ─▶ kaniko build ─▶ push to Harbor ─▶ Trivy scan report (image)
        ─▶ bump tag in GitLab ─▶ ArgoCD sync
```

Both scan steps are **report-only** (they log results; they don't fail the build). See
[APPSIM.md](APPSIM.md) for the full loop. Trigger a run:

```bash
oc -n jenkins start-build appsim-pipeline   # watch the SonarQube + Trivy stages in the log
```
