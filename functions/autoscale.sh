#!/usr/bin/env bash
# functions/autoscale.sh — load-driven worker autoscaler for platform "none"
# Sourced by deploy-okd.sh; not meant to be executed directly.
#
# OpenShift's native MachineAutoscaler/ClusterAutoscaler cannot work on this
# cluster: it is platform "none" with no Hetzner machine-api actuator, so
# MachineSets never reconcile into real servers. This re-creates the *behavior*
# people want from a MachineAutoscaler — "Pending pods appear -> add a worker;
# load clears -> remove a worker" — on top of the existing Terraform+CSR
# scaling primitive (apply_scale in functions/cluster-scale.sh).
#
# It is a foreground watch loop you start with `./deploy-okd.sh --autoscale`
# against a running cluster. Ctrl-C to stop. Workers only — never the control
# plane. Each scale action goes through the same terraform path as a manual
# `--scale`, so it is exactly as safe (drains on scale-down, CSR-approves on
# scale-up).

run_autoscale() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  [ -f "$KUBECONFIG" ] || err "no kubeconfig at $KUBECONFIG — deploy a cluster first"
  oc whoami >/dev/null 2>&1 || err "cannot reach the cluster (KUBECONFIG=$KUBECONFIG) — is it running?"

  local cur min max interval down_thresh down_needed down_streak cooldown_left
  cur=$(oc get nodes -o name 2>/dev/null | grep -c '/worker' || true)
  min=${FLAG_AUTOSCALE_MIN:-$cur}
  max=${FLAG_AUTOSCALE_MAX:-$((cur + 2))}
  interval=${FLAG_AUTOSCALE_INTERVAL:-60}
  down_thresh=${FLAG_AUTOSCALE_DOWN_THRESHOLD:-0.4}  # remaining workers must stay under this util to scale down
  down_needed=${FLAG_AUTOSCALE_DOWN_POLLS:-3}        # consecutive "DOWN" polls before acting (anti-flap)
  down_streak=0 cooldown_left=0

  case "$min$max$interval" in *[!0-9]*) err "--autoscale-min/--autoscale-max/--autoscale-interval must be integers";; esac
  [ "$min" -le "$max" ] || err "--autoscale-min ($min) cannot exceed --autoscale-max ($max)"
  [ "$interval" -ge 15 ] || err "--autoscale-interval must be >= 15 seconds"

  log "Autoscaler started (workers only). Ctrl-C to stop."
  cat <<INFO
    bounds        : $min..$max workers   (currently $cur)
    poll interval : ${interval}s
    scale UP when : a pod is Pending/Unschedulable for cpu or memory
    scale DOWN    : load fits on one fewer worker (<${down_thresh} util on both
                    cpu & mem) for $down_needed consecutive polls
    NOTE          : native MachineSets/MachineAutoscaler can't run on platform
                    "none"; this drives the same Terraform+CSR path as --scale
INFO

  local ptmp ntmp decision verdict reason
  ptmp=$(mktemp); ntmp=$(mktemp)
  trap 'rm -f "$ptmp" "$ntmp"; log "Autoscaler stopped."; return 0' INT TERM

  while :; do
    cur=$(oc get nodes -o name 2>/dev/null | grep -c '/worker' || true)
    if ! oc get pods -A -o json > "$ptmp" 2>/dev/null || ! oc get nodes -o json > "$ntmp" 2>/dev/null; then
      echo "    [$(date +%H:%M:%S)] cluster not reachable this poll — retrying in ${interval}s"
      sleep "$interval"; continue
    fi

    decision=$(python3 - "$ptmp" "$ntmp" "$cur" "$down_thresh" <<'PY'
import json, re, sys
pods   = json.load(open(sys.argv[1]))
nodes  = json.load(open(sys.argv[2]))
cur    = int(sys.argv[3])
thresh = float(sys.argv[4])

def cpu_m(v):           # "8" / "7500m" -> millicores
    if not v: return 0
    v=str(v)
    return int(float(v[:-1])) if v.endswith('m') else int(float(v)*1000)

def mem_b(v):           # "16331756Ki" / "2Gi" / "536870912" -> bytes
    if not v: return 0
    v=str(v); units={'Ki':1024,'Mi':1024**2,'Gi':1024**3,'Ti':1024**4,
                     'K':1000,'M':1000**2,'G':1000**3,'T':1000**4}
    for u,m in units.items():
        if v.endswith(u): return int(float(v[:-len(u)])*m)
    return int(float(v))

# worker nodes (this project names them workerNN.<domain>)
workers=[n for n in nodes['items'] if re.match(r'worker\d+\.', n['metadata']['name'])]
wnames={n['metadata']['name'] for n in workers}
alloc_cpu=sum(cpu_m(n['status'].get('allocatable',{}).get('cpu'))    for n in workers)
alloc_mem=sum(mem_b(n['status'].get('allocatable',{}).get('memory')) for n in workers)

# pods that can't be scheduled: 'pending' = fixable by adding a worker
# (resource starvation); 'unsched_any' = any unschedulable pod at all.
pending=0; unsched_any=0
for p in pods['items']:
    if p.get('status',{}).get('phase')!='Pending': continue
    for c in p['status'].get('conditions',[]):
        if c.get('type')=='PodScheduled' and c.get('status')=='False' \
           and c.get('reason')=='Unschedulable':
            unsched_any+=1
            # only resource starvation is fixable by adding identical workers;
            # taints/affinity/nodeSelector mismatches are not, so ignore them
            msg=c.get('message','') or ''
            if 'Insufficient' in msg or 'too many pods' in msg:
                pending+=1
            break

if pending>0:
    print(f"UP pending={pending}"); sys.exit()
# don't shrink while ANY pod is stuck unschedulable (even taint/affinity) —
# removing a worker can only make a stuck scheduler situation worse
if unsched_any>0:
    print(f"HOLD unschedulable={unsched_any}"); sys.exit()

# scale-down feasibility: would current requests still fit (under thresh) on
# one fewer worker? assume roughly uniform worker sizes.
if cur<=0 or len(workers)==0:
    print("HOLD no-workers"); sys.exit()
req_cpu=req_mem=0
for p in pods['items']:
    if p['spec'].get('nodeName') not in wnames: continue
    if p.get('status',{}).get('phase') in ('Succeeded','Failed'): continue
    for ct in p['spec'].get('containers',[]):
        r=ct.get('resources',{}).get('requests',{})
        req_cpu+=cpu_m(r.get('cpu')); req_mem+=mem_b(r.get('memory'))
remain=len(workers)-1
if remain<=0:
    cpu_ok=req_cpu==0; mem_ok=req_mem==0
else:
    rcpu=alloc_cpu*remain/len(workers); rmem=alloc_mem*remain/len(workers)
    cpu_ok = rcpu>0 and req_cpu < thresh*rcpu
    mem_ok = rmem>0 and req_mem < thresh*rmem
cu = (req_cpu/alloc_cpu) if alloc_cpu else 0
mu = (req_mem/alloc_mem) if alloc_mem else 0
if cpu_ok and mem_ok:
    print(f"DOWN cpu_util={cu:.0%} mem_util={mu:.0%}")
else:
    print(f"HOLD cpu_util={cu:.0%} mem_util={mu:.0%}")
PY
)
    verdict=${decision%% *}; reason=${decision#* }
    echo "    [$(date +%H:%M:%S)] workers=$cur  decision=$verdict  ($reason)"

    if [ "$cooldown_left" -gt 0 ]; then
      cooldown_left=$((cooldown_left - 1))
      echo "      cooling down after the last action ($cooldown_left poll(s) left)"
      down_streak=0; sleep "$interval"; continue
    fi

    case "$verdict" in
      UP)
        down_streak=0
        if [ "$cur" -ge "$max" ]; then
          echo "      at max ($max) — not scaling up"
        else
          log "Scaling UP: $cur -> $((cur+1)) worker(s) (pods waiting on resources)"
          CUR_WORKERS=$cur NEW_WORKERS=$((cur+1)) \
          CUR_MASTERS=$(oc get nodes -o name 2>/dev/null | grep -c '/master' || true) \
          NEW_MASTERS=$(oc get nodes -o name 2>/dev/null | grep -c '/master' || true) \
            apply_scale || echo "      WARNING: scale-up did not fully converge — see above"
          cooldown_left=2
        fi
        ;;
      DOWN)
        down_streak=$((down_streak + 1))
        if [ "$cur" -le "$min" ]; then
          echo "      at min ($min) — not scaling down"; down_streak=0
        elif [ "$down_streak" -ge "$down_needed" ]; then
          log "Scaling DOWN: $cur -> $((cur-1)) worker(s) (load fits on fewer workers)"
          CUR_WORKERS=$cur NEW_WORKERS=$((cur-1)) \
          CUR_MASTERS=$(oc get nodes -o name 2>/dev/null | grep -c '/master' || true) \
          NEW_MASTERS=$(oc get nodes -o name 2>/dev/null | grep -c '/master' || true) \
            apply_scale || echo "      WARNING: scale-down did not fully converge — see above"
          down_streak=0; cooldown_left=2
        else
          echo "      DOWN signal $down_streak/$down_needed (waiting to avoid flapping)"
        fi
        ;;
      *)
        down_streak=0
        ;;
    esac
    sleep "$interval"
  done
}
