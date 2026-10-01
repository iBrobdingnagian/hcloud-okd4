#!/usr/bin/env python3
"""Serve a live deploy/destroy progress page for the cluster workspaces.

Only two routes exist: / (the page) and /status.json[?cluster=NAME]. Nothing
else in the workspaces is served — they hold .env, SSH keys and kubeconfigs.

Workspaces are the repo root (the legacy cluster) and each .work/NAME. Without
?cluster= the page follows the one with a deploy/destroy running, else the one
operated on most recently. Progress comes from, in order of preference:
  logs/current-step.json  written by step()/progress_step (functions/progress.sh)
  running child processes  e.g. 'make wait_bootstrap' => bootstrap step
  .phases/ checkpoints     deploy only
plus logs/last-operation.json for the outcome and, when the operator opted in,
a console transcript (logs/deploy-console.log) with credential lines redacted.

Started automatically by deploy-okd.sh / destroy-okd.sh (functions/progress.sh).
Usage: scripts/progress_server.py [--port 8093] [--bind 0.0.0.0]
"""
import argparse
import json
import os
import re
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

REPO = Path(__file__).resolve().parent.parent
PAGE = Path(__file__).resolve().parent / 'progress.html'

# per operation: ordered (step title prefix, typical duration, finishing checkpoint)
OPERATIONS = {
    'deploy': [
        ('Updating .env and install-config.yaml', 'instant', 'configured'),
        ('Toolbox image', 'skipped if cached, else 5-10 min', 'ignition'),
        ('Generating manifests and ignition configs', '~1 min', 'ignition'),
        ('CoreOS image', 'skipped if a snapshot exists, else 2-5 min', 'image'),
        ('Deploying infrastructure', '3-5 min', 'bootstrap-complete'),
        ('Waiting for the bootstrap machine-config server', '2-6 min', 'bootstrap-complete'),
        ('Waiting for bootstrap to complete', '15-40 min (longest phase)', 'bootstrap-complete'),
        ('Removing bootstrap + ignition nodes', '1-2 min', 'bootstrap-removed'),
        ('Waiting for install completion', '5-25 min', 'installed'),
        ('Approving CSRs until all', '2-10 min', 'ready'),
    ],
    'destroy': [
        ('Verifying cluster ownership', '<1 min', None),
        ('Confirming teardown', "waits for 'yes' (skipped with --yes)", None),
        ('Removing cluster-autoscaler nodes', '<1 min', None),
        ('Destroying infrastructure with terraform', '2-5 min', None),
        ('Cleaning up local state', 'instant', None),
    ],
}
SCRIPTS = {'deploy-okd.sh': 'deploy', 'destroy-okd.sh': 'destroy'}
# command fragments in the run's child processes that identify a step
MARKERS = {
    'deploy': [
        ('make fetch', 1), ('make build', 1), ('make generate_', 2),
        ('make hcloud_image', 3), ('coreos print-stream-json', 3),
        ('make infrastructure BOOTSTRAP=true', 4), ('22623/healthz', 5),
        ('make wait_bootstrap', 6), ('make infrastructure', 7),
        ('make wait_completion', 8), ('certificate approve', 9), ('get csr', 9),
    ],
    'destroy': [('make destroy', 3)],
}
CHECKPOINTS = ['configured', 'ignition', 'image', 'bootstrap-complete',
               'bootstrap-removed', 'installed', 'ready']

ANSI = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
STEP_RE = re.compile(r'^Phase (\d+) — (.+)$')
ELAPSED_RE = re.compile(r'elapsed: (\S+) \| typical duration of this step: (.+)$')
SECRET_RE = re.compile(r'pass(word|wd)?|token|secret|api[_-]?key|private key|auth', re.I)

_BOOT = next(float(l.split()[1]) for l in open('/proc/stat') if l.startswith('btime'))
_TICK = os.sysconf('SC_CLK_TCK')
_seen = {}  # run pid -> {'index', 'since'}: keeps the inferred step between commands


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def workspaces():
    found = {'legacy': REPO}
    for d in sorted((REPO / '.work').glob('*/')):
        if (d / 'cluster.json').is_file() and not d.is_symlink():
            found[d.name] = d
    return found


def all_processes():
    """{cwd: [(pid, start_epoch, cmdline)]} for every readable process."""
    out = {}
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            cwd = os.readlink(proc / 'cwd')
            cmd = (proc / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
            stat = (proc / 'stat').read_text()
            start = _BOOT + int(stat.rsplit(')', 1)[1].split()[19]) / _TICK
        except (OSError, ValueError, IndexError):
            continue
        out.setdefault(cwd, []).append((int(proc.name), start, cmd))
    return out


def running_op(procs):
    """(operation, pid, start) of the deploy/destroy script running in a workspace."""
    runs = [(op, p) for p in procs for script, op in SCRIPTS.items() if script in p[2]]
    if not runs:
        return None
    op, (pid, start, _) = min(runs, key=lambda r: r[1][1])
    return op, pid, start


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def step_index(op, title):
    return next((i for i, s in enumerate(OPERATIONS[op]) if title.startswith(s[0])), None)


def read_console(path, tail=40):
    if not path.is_file():
        return None
    lines = [ANSI.sub('', l).rstrip() for l in path.read_text(errors='replace').splitlines()]
    seen = []
    for i, line in enumerate(lines):
        m = STEP_RE.match(line.strip())
        if m:
            step = {'title': m.group(2), 'elapsed': None, 'typical': None}
            e = ELAPSED_RE.search(lines[i + 1] if i + 1 < len(lines) else '')
            if e:
                step['elapsed'], step['typical'] = e.group(1), e.group(2)
            seen.append(step)
    errors = [l.strip() for l in lines if l.strip().startswith('ERROR')]
    shown = ['[line redacted]' if SECRET_RE.search(l) else l for l in lines if l.strip()][-tail:]
    return {'steps': seen, 'tail': shown, 'error': errors[-1] if errors else None,
            'updated': iso(path.stat().st_mtime)}


def status(name, work, procs):
    run = running_op(procs)
    last = read_json(work / 'logs' / 'last-operation.json')
    marker_file = work / 'logs' / 'current-step.json'
    marker = read_json(marker_file)
    marker_at = marker_file.stat().st_mtime if marker else 0
    checkpoints = [{'name': c, 'at': (work / '.phases' / c).read_text().strip()
                    if (work / '.phases' / c).is_file() else None} for c in CHECKPOINTS]
    done_cps = {c['name'] for c in checkpoints if c['at']}

    if run:
        op, pid, started = run
    else:
        op = (last or {}).get('operation') or (marker or {}).get('op') or 'deploy'
        op = op if op in OPERATIONS else 'deploy'
        pid, started = None, None
    steps = OPERATIONS[op]

    current = None
    # 1) the run's own marker (older deploys wrote no 'op' field)
    if marker and marker.get('op', 'deploy') == op and (not run or marker_at >= started - 1):
        idx = step_index(op, marker.get('title', ''))
        if idx is not None:
            current = {'index': idx, 'title': marker['title'], 'typical': marker.get('typical'),
                       'since': marker.get('at'), 'source': 'marker'}
    if run and not current:
        # 2) infer from the child processes running right now; highest step wins
        found = None
        for _, pstart, cmd in procs:
            for frag, idx in MARKERS[op]:
                if frag in cmd:
                    if not found or idx > found[0]:
                        found = (idx, pstart)
                    break
        prev = _seen.get(pid)
        if found and (not prev or found[0] > prev['index']):
            _seen[pid] = {'index': found[0], 'since': found[1]}
        if pid not in _seen:
            # 3) fallback: the first step whose checkpoint is missing
            idx = next((i for i, s in enumerate(steps) if s[2] and s[2] not in done_cps), 0)
            _seen[pid] = {'index': idx, 'since': None}
        cur = _seen[pid]
        current = {'index': cur['index'], 'title': steps[cur['index']][0],
                   'typical': steps[cur['index']][1],
                   'since': iso(cur['since']) if cur['since'] else None, 'source': 'processes'}

    finished_ok = (not run and last is not None and last.get('operation') == op
                   and last.get('exit_code') == 0)
    return {
        'cluster': name,
        'clusters': list(workspaces()),
        'operation': op,
        'now': datetime.now(timezone.utc).isoformat(),
        'running': run is not None,
        'started': iso(started) if started else None,
        'current': current,
        'complete': finished_ok,
        'steps': [s[0] for s in steps],
        'step_checkpoint': [s[2] for s in steps],
        'checkpoints': checkpoints,
        'last_operation': last,
        'console': read_console(work / 'logs' / 'deploy-console.log') if op == 'deploy' else None,
    }


def pick(requested):
    spaces = workspaces()
    by_cwd = all_processes()
    if requested in spaces:
        name = requested
    else:
        active = [n for n, w in spaces.items() if running_op(by_cwd.get(str(w), []))]
        if active:
            name = active[0]
        else:
            def last_op(n):
                f = spaces[n] / 'logs' / 'last-operation.json'
                return f.stat().st_mtime if f.is_file() else 0
            name = max(spaces, key=last_op)
    work = spaces[name]
    return status(name, work, by_cwd.get(str(work), []))


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path in ('/', '/index.html'):
            self._send(200, PAGE.read_bytes(), 'text/html; charset=utf-8')
        elif url.path == '/status.json':
            requested = parse_qs(url.query).get('cluster', [''])[0]
            self._send(200, json.dumps(pick(requested)).encode(), 'application/json')
        else:
            self._send(404, b'not found', 'text/plain')

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--port', type=int, default=8093)
    ap.add_argument('--bind', default='0.0.0.0')
    a = ap.parse_args()
    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    print(f'progress page for {REPO} on http://{a.bind}:{a.port}/', flush=True)
    srv.serve_forever()


if __name__ == '__main__':
    main()
