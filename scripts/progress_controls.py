"""Authenticated browser controls; all cloud work stays in the lifecycle scripts."""
import fcntl
import os
from pathlib import Path
import re
import secrets
import subprocess
import threading


class Controls:
    def __init__(self, repo):
        self.repo = Path(repo)
        self.token = secrets.token_urlsafe(32)
        self.jobs = {}
        self.lock = threading.Lock()

    def save_token(self):
        path = self.repo / 'logs/progress-control-token'
        path.parent.mkdir(mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(self.token + '\n')

    def clusters(self):
        return ['legacy'] + sorted(p.stem for p in (self.repo / 'clusters').glob('*.yaml')
                                   if not p.is_symlink() and p.stem != 'legacy'
                                   and re.fullmatch(r'[a-z][a-z0-9-]{0,30}', p.stem))

    def command(self, data):
        if not isinstance(data, dict) or set(data) - {'cluster', 'operation', 'options', 'confirm'}:
            raise ValueError('Invalid operation request.')
        cluster, operation = data.get('cluster'), data.get('operation')
        if cluster not in self.clusters():
            raise ValueError('Choose an existing cluster configuration or legacy.')
        if operation not in ('deploy', 'resume', 'destroy'):
            raise ValueError('Choose deploy, resume, or destroy.')
        if data.get('confirm') != f'{operation} {cluster}':
            raise ValueError(f'Type "{operation} {cluster}" to confirm.')
        options = data.get('options', {})
        if not isinstance(options, dict):
            raise ValueError('Invalid deployment options.')
        script = 'destroy' if operation == 'destroy' else 'deploy'
        args = ['bash', str(self.repo / f'{script}-okd.sh'), '--yes']
        if cluster != 'legacy':
            args += ['--cluster', cluster]
        if operation == 'resume':
            args += ['--resume']
        # Named clusters use their pinned YAML; resume uses its checkpoints.
        if operation != 'deploy' or cluster != 'legacy':
            if options:
                raise ValueError('This operation uses the recorded cluster configuration.')
            return args
        patterns = {
            'profile': r'[1234]', 'region': r'[a-z0-9-]+',
            'lab-topology': r'(?:1x[0123]|3x3)', 'lab-tier': r'(?:low|mid|high)',
            'masters': r'(?:1|3|5)', 'workers': r'[0-9]{1,3}',
            'master-type': r'[a-z0-9-]+', 'worker-type': r'[a-z0-9-]+',
            'release': r'[0-9]+\.[0-9]+[a-zA-Z0-9_.-]*',
            'duration': r'[1-9][0-9]*m?',
        }
        for key, value in options.items():
            if key == 'no-autodestroy':
                if type(value) is not bool:
                    raise ValueError('Invalid automatic teardown option.')
                if value:
                    args.append('--no-autodestroy')
            elif key in patterns and isinstance(value, str) and len(value) <= 100 and re.fullmatch(patterns[key], value):
                args += ['--' + key, value]
            else:
                raise ValueError(f'Invalid deployment option: {key}')
        profile = options.get('profile', '2')
        if any(k in options for k in ('lab-topology', 'lab-tier')) and profile != '3':
            raise ValueError('Lab options require the Lab profile.')
        if any(k in options for k in ('masters', 'workers', 'master-type', 'worker-type')) and profile != '4':
            raise ValueError('Custom node options require the Manual profile.')
        return args

    def launch(self, data):
        args = self.command(data)
        cluster = data['cluster']
        with self.lock:
            previous = self.jobs.get(cluster)
            if previous and previous['process'].poll() is None:
                raise BlockingIOError('A browser operation is already running for this cluster.')
            lock_path = self.repo / '.work/locks' / f'{cluster}.lock'
            if lock_path.exists():
                with lock_path.open('r') as stream:
                    try:
                        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError as exc:
                        raise BlockingIOError('Another operation is already running for this cluster.') from exc
                    # The lifecycle parent takes the authoritative lock after launch;
                    # this early check avoids replacing output for an active CLI run.
                    fcntl.flock(stream, fcntl.LOCK_UN)
            # Never inherit the context of the deployment that started this server:
            # doing so bypasses cluster_dispatch and its per-cluster operation lock.
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('HCLOUD_OKD4_', 'TF_VAR_', 'TF_CLI_ARGS'))
                   and k not in ('CLUSTER_ID', 'CLUSTER_CONFIG', 'AUTODESTROY_ID',
                                 'KUBECONFIG', 'TF_WORKSPACE', 'TF_DATA_DIR')}
            env['PROGRESS_SERVER'] = '0'
            path = self.repo / 'logs' / f'web-{cluster}.log'
            path.parent.mkdir(mode=0o700, exist_ok=True)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as output:
                os.fchmod(output.fileno(), 0o600)
                child = subprocess.Popen(args, cwd=self.repo, env=env, stdin=subprocess.DEVNULL,
                                         stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            self.jobs[cluster] = {'process': child, 'operation': data['operation'], 'log': path}
            # Reap completed children even when nobody has the page open.
            threading.Thread(target=child.wait, daemon=True).start()
            return {'cluster': cluster, 'operation': data['operation'],
                    'status_url': '/?cluster=' + cluster}

    def snapshot(self):
        with self.lock:
            jobs = {}
            for name, job in self.jobs.items():
                code = job['process'].poll()
                # Only authenticated operators can read browser-run output.
                with job['log'].open('rb') as stream:
                    stream.seek(0, os.SEEK_END)
                    size = stream.tell()
                    stream.seek(max(0, size - 16000))
                    tail = stream.read().decode(errors='replace')
                jobs[name] = {'operation': job['operation'], 'running': code is None,
                              'exit_code': code, 'tail': tail}
            return {'clusters': self.clusters(), 'jobs': jobs}
