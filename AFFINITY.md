# Affinity & Anti-Affinity (the label-driven way)

How to control **where pods land** on an OKD/OpenShift cluster using *labels*.
Everything here works with plain `oc`/`kubectl` — no operators required.

The label-first model has three moving parts:

1. **Node labels** — describe a node (`disktype=ssd`, `zone=a`, `role=kafka`).
2. **Pod labels** — describe a workload (`app=kafka`, `tier=db`).
3. **Affinity rules** — a pod's spec references those labels to say
   *"schedule me near / away from nodes or pods carrying label X"*.

> **Rule of thumb**
> - **nodeAffinity / nodeSelector** → pod ↔ **node** label (run *here*).
> - **podAffinity** → pod ↔ **other pods'** labels (run *together*).
> - **podAntiAffinity** → pod ↔ **other pods'** labels (run *apart*).
>
> Each rule is either **required** (hard — won't schedule otherwise) or
> **preferred** (soft — best effort, with a `weight` 1–100).

---

## 1. Work with labels

### Nodes

```bash
# show every node's labels
oc get nodes --show-labels

# show nodes with just one label column (e.g. the built-in hostname)
oc get nodes -L kubernetes.io/hostname -L topology.kubernetes.io/zone

# add a label to a node
oc label node worker01.okd4.example.com disktype=ssd

# add the same label to several nodes at once (by selector)
oc label node -l node-role.kubernetes.io/worker= workload=apps

# overwrite an existing label
oc label node worker01.okd4.example.com disktype=nvme --overwrite

# remove a label (note the trailing minus)
oc label node worker01.okd4.example.com disktype-
```

### Pods (via the workload template, not the live pod)

Pods are labelled through their Deployment/StatefulSet `template.metadata.labels`
so the labels survive rollouts:

```bash
# see pod labels
oc -n myns get pods --show-labels

# add a label to a Deployment's pod template (triggers a rollout)
oc -n myns patch deploy myapp --type=merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"app":"myapp","tier":"web"}}}}}'
```

Built-in labels you'll reference constantly as a **topologyKey**:

| Label | Meaning |
|-------|---------|
| `kubernetes.io/hostname` | one bucket **per node** (spread/pack across nodes) |
| `topology.kubernetes.io/zone` | one bucket **per zone** (spread across zones) |

---

## 2. nodeSelector — the simplest label match

Pins a pod to nodes that carry **all** the given labels. Hard requirement, no
syntax beyond a map. Good when you just need "must run on SSD nodes".

```yaml
spec:
  template:
    spec:
      nodeSelector:
        disktype: ssd
```

```bash
oc -n myns patch deploy myapp --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"disktype":"ssd"}}}}}'
```

---

## 3. nodeAffinity — match nodes by label (with operators)

More expressive than `nodeSelector`: supports `In`, `NotIn`, `Exists`,
`DoesNotExist`, `Gt`, `Lt`, and soft preferences.

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          # HARD: only schedule on SSD or NVMe nodes
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - { key: disktype, operator: In, values: [ssd, nvme] }
          # SOFT: prefer zone "a", but don't fail if none free
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 50
            preference:
              matchExpressions:
              - { key: topology.kubernetes.io/zone, operator: In, values: [a] }
```

---

## 4. podAntiAffinity — spread replicas apart (the common one)

Keep replicas of the same app off the same node, so one node failure can't take
out every replica. The pod references **its own** label (`app=myapp`) and a
`topologyKey` that defines "apart".

```yaml
spec:
  selector:
    matchLabels: { app: myapp }
  template:
    metadata:
      labels: { app: myapp }          # <- the label the rule matches
    spec:
      affinity:
        podAntiAffinity:
          # HARD: never two 'myapp' pods on the same node
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels: { app: myapp }
            topologyKey: kubernetes.io/hostname
```

Prefer **soft** anti-affinity when you have more replicas than nodes (hard would
leave the extras stuck `Pending`):

```yaml
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels: { app: myapp }
              topologyKey: kubernetes.io/hostname
```

> **Modern alternative:** `topologySpreadConstraints` give finer control over
> even spreading (`maxSkew`) and are often preferred over preferred-anti-affinity
> for large deployments — but anti-affinity is the classic, widely-supported tool.

---

## 5. podAffinity — co-locate workloads

The inverse: pull a pod *onto* nodes already running pods with a given label
(e.g. keep a cache next to its app to cut latency).

```yaml
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels: { app: web }   # run me where 'web' runs
            topologyKey: kubernetes.io/hostname
```

---

## 6. Patch affinity onto an existing workload

You rarely hand-edit; patch the template instead. Example — add hard
anti-affinity to an existing Deployment:

```bash
oc -n myns patch deploy myapp --type=merge -p '{
  "spec": { "template": { "spec": { "affinity": {
    "podAntiAffinity": {
      "requiredDuringSchedulingIgnoredDuringExecution": [
        { "labelSelector": { "matchLabels": { "app": "myapp" } },
          "topologyKey": "kubernetes.io/hostname" }
      ]
    }
  }}}}
}'
```

To **remove** an affinity block again:

```bash
oc -n myns patch deploy myapp --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/affinity"}]'
```

---

## 7. Worked example — spread Kafka brokers across worker nodes

This pins the Kafka StatefulSet (see `functions/devops.sh`) to worker nodes and
keeps each broker on a different node:

```bash
# 1) label the workers you want Kafka on
oc label node -l node-role.kubernetes.io/worker= workload=kafka --overwrite

# 2) patch the StatefulSet: nodeAffinity (workers) + podAntiAffinity (spread)
oc -n kafka patch statefulset kafka --type=merge -p '{
  "spec": { "template": { "spec": { "affinity": {
    "nodeAffinity": {
      "requiredDuringSchedulingIgnoredDuringExecution": {
        "nodeSelectorTerms": [
          { "matchExpressions": [
            { "key": "workload", "operator": "In", "values": ["kafka"] } ] } ]
      }
    },
    "podAntiAffinity": {
      "requiredDuringSchedulingIgnoredDuringExecution": [
        { "labelSelector": { "matchLabels": { "app": "kafka" } },
          "topologyKey": "kubernetes.io/hostname" }
      ]
    }
  }}}}
}'
```

---

## 8. Verify it worked

```bash
# which node did each pod land on?
oc -n myns get pods -o wide

# confirm pods are on distinct nodes (anti-affinity)
oc -n myns get pods -o wide --no-headers | awk '{print $7}' | sort | uniq -c

# if a pod is stuck Pending, the scheduler tells you why (look for
# 'didn't match pod anti-affinity rules' or 'node(s) didn't match nodeSelector')
oc -n myns describe pod <pod> | sed -n '/Events:/,$p'
```

---

## 9. Drain a node (cordon → drain → uncordon)

Draining safely moves workloads **off** a node — for maintenance, a reboot, or
before deleting it. It's the flip side of scheduling: a drained node is
**cordoned** (marked unschedulable), so the scheduler must place the evicted
pods elsewhere using their affinity rules.

```bash
# 1) cordon: stop NEW pods landing here (existing pods keep running)
oc adm cordon worker01.okd4.example.com

# 2) drain: evict the running pods (this also cordons if you skipped step 1)
oc adm drain worker01.okd4.example.com \
  --ignore-daemonsets \         # DaemonSet pods can't be moved; skip them
  --delete-emptydir-data \      # allow evicting pods using emptyDir volumes
  --force \                     # also evict bare/standalone pods (no controller)
  --grace-period=60 \           # seconds to let pods shut down cleanly
  --timeout=5m                  # give up if it can't finish in time

# 3) do the maintenance (reboot, resize, replace disk, …)

# 4) uncordon: make the node schedulable again
oc adm uncordon worker01.okd4.example.com
```

```bash
# check schedulability — SchedulingDisabled means cordoned
oc get nodes
# NAME                          STATUS                     ROLES    ...
# worker01.okd4.example.com     Ready,SchedulingDisabled   worker   ...

# watch pods leave the node while it drains
oc get pods -A -o wide --field-selector spec.nodeName=worker01.okd4.example.com -w
```

**How draining interacts with affinity / PodDisruptionBudgets**

- **PodDisruptionBudgets (PDBs) gate the drain.** `drain` evicts via the
  eviction API, which respects PDBs (`minAvailable` / `maxUnavailable`). If
  evicting would breach a budget, the drain **blocks and retries** until it's
  safe — so quorum apps (Kafka, etcd, databases) stay available. Add a PDB to
  protect a replicated app:

  ```bash
  oc -n kafka create pdb kafka-pdb --selector=app=kafka --min-available=2
  ```

- **Hard anti-affinity can wedge a drain.** If `app=myapp` uses
  `requiredDuringScheduling` anti-affinity with `topologyKey=hostname` and every
  *other* node already runs a `myapp` pod, the evicted pod has nowhere legal to
  go and stays `Pending` (the drain may hang on its `--timeout`). Keep a spare
  node, or use **preferred** anti-affinity, for this case.

- DaemonSet pods are re-created on the node and are expected to stay; that's why
  `--ignore-daemonsets` is effectively required.

> ⚠️ **Don't drain a control-plane/master node** unless you know etcd quorum
> survives it. Drain one node at a time and confirm the cluster is healthy
> (`oc get nodes`, `oc get co`) before moving to the next.

---

## Gotchas

- **`requiredDuringScheduling…` is a hard gate.** If no node satisfies it, the
  pod stays `Pending` forever. With anti-affinity, you need **at least as many
  matching nodes as replicas**. Use `preferred…` when unsure.
- **`…IgnoredDuringExecution`** means rules are evaluated **only at scheduling
  time** — relabeling a node later does *not* evict already-running pods.
- **topologyKey is mandatory** for pod (anti-)affinity and must be a label that
  exists on nodes. `kubernetes.io/hostname` = per-node; zone label = per-zone.
- **The pod's own label must actually be set** in `template.metadata.labels` —
  anti-affinity matching `app=myapp` does nothing if the pods aren't labelled
  `app=myapp`.
- **Don't label the live pod** for this; label the controller's pod template so
  the labels and rules persist across rollouts.
```
