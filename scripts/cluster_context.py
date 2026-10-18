#!/usr/bin/env python3
"""Validate cluster configuration and isolate lifecycle commands; never shell-source secrets."""
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import urllib.request

try:
    import yaml
except ImportError:
    raise SystemExit('PyYAML is required; install requirements-dev.txt in your Python environment.')


class ConfigError(ValueError):
    pass


def read_env(path):
    values = {}
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('export '):
            line = line[7:]
        key, sep, value = line.partition('=')
        if not sep or not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', key):
            raise ConfigError(f'{path}:{number}: expected KEY=value')
        # Literal dotenv values: no substitution, expansion, or execution.
        if value.startswith(('"', "'")):
            parts = shlex.split(value, comments=True)
            if len(parts) != 1:
                raise ConfigError(f'{path}:{number}: invalid quoted value')
            value = parts[0]
        else:
            value = re.split(r'\s+#', value, maxsplit=1)[0].rstrip()
        if '\n' in value or '\r' in value or '\x00' in value:
            raise ConfigError(f'{path}:{number}: multiline values are unsupported')
        values[key] = value
    return values


def atomic_write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_env(path, values):
    # Docker --env-file reads literal values; do not add shell quotes.
    atomic_write(path, ''.join(f'{key}={value}\n' for key, value in sorted(values.items())))


def mapping(value, keys, where):
    if not isinstance(value, dict) or set(value) - set(keys):
        raise ConfigError(f'{where}: expected a mapping with keys: {", ".join(keys)}')
    return value


def token(value, pattern, where):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise ConfigError(f'{where}: invalid or missing value')
    return value


def load_config(repo, name):
    token(name, r'[a-z][a-z0-9-]{0,30}', 'cluster name')
    path = repo / 'clusters' / f'{name}.yaml'
    data = mapping(yaml.safe_load(path.read_text()), (
        'name', 'domain', 'zone_id', 'release', 'region', 'network_zone', 'masters',
        'workers', 'master_type', 'worker_type', 'ignition_type', 'credentials_file',
        'ssh_private_key', 'pull_secret_file', 'distribution', 'network', 'duration', 'autodestroy',
    ), str(path))
    if data.get('name') != name:
        raise ConfigError(f'{path}: name must match --cluster {name}')
    token(data.get('domain'), r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?', 'domain')
    labels = data['domain'].split('.')
    if len(labels) < 3 or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', x) for x in labels):
        raise ConfigError('domain must be a cluster hostname, e.g. dev.example.com')
    token(data.get('zone_id'), r'[A-Za-z0-9_-]+', 'zone_id')
    token(data.get('release'), r'[0-9]+\.[0-9]+\.[A-Za-z0-9_.-]+', 'release (full pinned tag)')
    if data.setdefault('distribution', 'okd') not in ('okd', 'openshift'):
        raise ConfigError('distribution must be okd or openshift')
    if data['distribution'] == 'openshift':
        token(data['release'], r'4\.[0-9]+\.[0-9]+', 'pinned OpenShift release')
        if not data.get('pull_secret_file'):
            raise ConfigError('OpenShift requires pull_secret_file')
    for key in ('region', 'network_zone', 'master_type', 'worker_type', 'ignition_type'):
        token(data.get(key), r'[a-z0-9-]+', key)
    for key in ('masters', 'workers'):
        if type(data.get(key)) is not int or data[key] < (1 if key == 'masters' else 0):
            raise ConfigError(f'{key}: invalid replica count')
    if data['masters'] not in (1, 3, 5):
        raise ConfigError('masters must be 1, 3, or 5')
    for key in ('credentials_file', 'ssh_private_key'):
        if not isinstance(data.get(key), str) or not data[key]:
            raise ConfigError(f'{key}: a file path is required')
    token(str(data.setdefault('duration', '8')), r'(?:[1-9][0-9]*)(?:m)?', 'duration')
    if type(data.setdefault('autodestroy', False)) is not bool:
        raise ConfigError('autodestroy must be true or false')
    net = mapping(data.get('network'), ('machine', 'nodes', 'load_balancer', 'pods', 'services', 'host_prefix'), 'network')
    networks = {}
    for key in ('machine', 'nodes', 'load_balancer', 'pods', 'services'):
        networks[key] = ipaddress.IPv4Network(net.get(key, ''), strict=True)
    for key in ('nodes', 'load_balancer'):
        if not networks[key].subnet_of(networks['machine']):
            raise ConfigError(f'network.{key} must be inside network.machine')
        if networks[key].num_addresses < 8:
            raise ConfigError(f'network.{key} must provide at least eight addresses')
    if networks['nodes'].overlaps(networks['load_balancer']):
        raise ConfigError('node and load-balancer subnets overlap')
    for a, b in (('machine', 'pods'), ('machine', 'services'), ('pods', 'services')):
        if networks[a].overlaps(networks[b]):
            raise ConfigError(f'network.{a} overlaps network.{b}')
    prefix = net.setdefault('host_prefix', 23)
    if type(prefix) is not int or not networks['pods'].prefixlen < prefix <= 30:
        raise ConfigError('network.host_prefix must be larger than the pod CIDR prefix and at most 30')
    # Domain reuse is unsafe even when networks are intentionally isolated.
    for other in sorted((repo / 'clusters').glob('*.yaml')):
        if other == path:
            continue
        candidate = yaml.safe_load(other.read_text())
        if isinstance(candidate, dict) and candidate.get('domain') == data['domain']:
            raise ConfigError(f'domain already used by {other.name}')
    if (repo / '.env').exists() and read_env(repo / '.env').get('TF_VAR_dns_domain') == data['domain']:
        raise ConfigError('domain belongs to the legacy .env; keep using legacy commands for this cluster')
    return data


def config_env(data):
    return {
        'TF_VAR_cluster_id': data['name'], 'TF_VAR_dns_domain': data['domain'],
        'TF_VAR_dns_zone_id': data['zone_id'], 'OPENSHIFT_RELEASE': data['release'],
        'DEPLOYMENT_TYPE': data.get('distribution', 'okd'), 'TF_VAR_location': data['region'],
        'TF_VAR_network_zone': data['network_zone'],
        'TF_VAR_replicas_master': str(data['masters']), 'TF_VAR_replicas_worker': str(data['workers']),
        'TF_VAR_server_type_master': data['master_type'], 'TF_VAR_server_type_worker': data['worker_type'],
        'TF_VAR_server_type_bootstrap': data['master_type'], 'TF_VAR_server_type_ignition': data['ignition_type'],
        'PACKER_LOCATION': data['region'], 'PACKER_SERVER_TYPE': data['ignition_type'], 'TF_VAR_fcos_release': '',
        'TF_VAR_network_cidr': data['network']['machine'], 'TF_VAR_subnet_cidr': data['network']['nodes'],
        'TF_VAR_lb_subnet_cidr': data['network']['load_balancer'],
    }


def sync_sources(repo, work):
    for filename in ('Makefile', 'Dockerfile', '.dockerignore'):
        shutil.copy2(repo / filename, work / filename)
    for directory in ('terraform', 'ansible', 'packer', 'grafana'):
        for source in (repo / directory).rglob('*'):
            relative = source.relative_to(repo)
            if '.terraform' in relative.parts or source.is_symlink() or not source.is_file():
                continue
            if source.name.endswith(('.tfvars', '.tfvars.json')):
                continue
            if source.suffix not in ('.tf', '.tpl', '.ign', '.conf', '.cfg', '.yml', '.yaml', '.json', '.py', '.hcl'):
                continue
            target = work / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)


def prepare(repo, name, operation, resume=False):
    data = load_config(repo, name)
    work = repo / '.work' / name
    if work.is_symlink():
        raise ConfigError('cluster working directory cannot be a symlink')
    identity = work / 'cluster.json'
    if operation != 'deploy' and not identity.exists():
        raise ConfigError(f'cluster {name} has no local deployment; refusing {operation}')
    if resume and not (work / '.phases' / 'configured').exists():
        raise ConfigError('--resume requires an existing deployment checkpoint')
    if identity.exists():
        previous = json.loads(identity.read_text())
        for key in ('name', 'domain', 'zone_id', 'release', 'region', 'network_zone', 'network'):
            if previous[key] != data[key]:
                raise ConfigError(f'{key} changed for existing cluster {name}; use its original configuration')
    credentials = read_env(repo / data['credentials_file'])
    # Configuration cannot be overridden by a credentials file or inherited TF_VARs.
    protected = {'REPO_ROOT', 'CLUSTER_ID', 'AUTODESTROY_ID', 'PATH', 'PYTHONPATH', 'BASH_ENV', 'ENV', 'HOME', 'PWD', 'KUBECONFIG'}
    if any(k.startswith(('TF_', 'FLAG_', 'HCLOUD_OKD4_')) or k in protected or k in config_env(data) for k in credentials):
        raise ConfigError('credentials_file must contain credentials only, not deployment configuration')
    for key in ('HCLOUD_TOKEN', 'CLOUDFLARE_API_TOKEN'):
        if not credentials.get(key):
            raise ConfigError(f'{key} missing from credentials_file')
    key = repo / data['ssh_private_key']
    public_key = Path(str(key) + '.pub').read_text().strip()
    if not public_key.startswith(('ssh-', 'ecdsa-')) or '\n' in public_key:
        raise ConfigError('SSH public key must contain one OpenSSH public key')
    private_key = key.read_bytes()
    pull_secret = '{"auths":{"none":{"auth":"none"}}}'
    if data.get('pull_secret_file'):
        pull_secret = json.dumps(json.loads((repo / data['pull_secret_file']).read_text()))
    if data.get('distribution') == 'openshift':
        from openshift_config import validate_pull_secret
        try:
            validate_pull_secret(pull_secret)
        except (ValueError, AttributeError, TypeError):
            raise ConfigError('OpenShift requires valid Red Hat registry credentials in pull_secret_file')
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    work.chmod(0o700)
    values = config_env(data)
    if (work / '.env').exists():
        previous = read_env(work / '.env')
        for key in ('TF_VAR_cluster_id', 'TF_VAR_dns_domain', 'TF_VAR_dns_zone_id', 'OPENSHIFT_RELEASE',
                    'DEPLOYMENT_TYPE', 'TF_VAR_location', 'TF_VAR_network_zone', 'TF_VAR_network_cidr',
                    'TF_VAR_subnet_cidr', 'TF_VAR_lb_subnet_cidr'):
            if previous.get(key) != values[key]:
                raise ConfigError(f'generated {key} differs from cluster identity; refusing operation')
        values.update(previous)  # retain resolved topology and image release
    values.update(credentials)
    write_env(work / '.env', values)
    atomic_write(work / 'okd4_new_id_rsa', private_key.decode())
    # Only render once: installer credentials/identity are never regenerated on resume.
    if not (work / 'install-config.yaml').exists():
        cluster_name, base_domain = data['domain'].split('.', 1)
        install = {
            'apiVersion': 'v1', 'baseDomain': base_domain, 'metadata': {'name': cluster_name},
            'controlPlane': {'name': 'master', 'replicas': data['masters'], 'hyperthreading': 'Enabled'},
            'compute': [{'name': 'worker', 'replicas': 0, 'hyperthreading': 'Enabled'}],
            'networking': {'networkType': 'OVNKubernetes',
                          'clusterNetwork': [{'cidr': data['network']['pods'], 'hostPrefix': data['network']['host_prefix']}],
                          'serviceNetwork': [data['network']['services']]},
            'platform': {'none': {}}, 'pullSecret': pull_secret, 'sshKey': public_key,
        }
        atomic_write(work / 'install-config.yaml', yaml.safe_dump(install))
    sync_sources(repo, work)
    if not identity.exists():
        atomic_write(identity, json.dumps(data, indent=2) + '\n')
    return work, data


@contextlib.contextmanager
def operation_lock(repo, name):
    locks = repo / '.work' / 'locks'
    locks.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (locks / f'{name}.lock').open('a+') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ConfigError(f'another operation is running for cluster {name}') from exc
        yield


def preview(repo, name):
    data = load_config(repo, name)
    work = repo / '.work' / name
    current = read_env(work / '.env') if (work / '.env').exists() else {}
    print(f'Cluster: {name}\nDomain: {data["domain"]}\nRegion: {data["region"]}\nRelease: {data["release"]}')
    for role in ('master', 'worker'):
        print(f'{role}s: {current.get("TF_VAR_replicas_" + role, "not deployed")} -> {data[role + "s"]} ({data[role + "_type"]})')
    print('Network: ' + json.dumps(data['network'], sort_keys=True))
    print(f'State and credentials: {work}\nAuto-destroy: {data["autodestroy"]}')
    credentials_path = repo / data['credentials_file']
    credentials = read_env(credentials_path) if credentials_path.exists() else {}
    if credentials.get('HCLOUD_TOKEN'):
        request = urllib.request.Request('https://api.hetzner.cloud/v1/pricing', headers={
            'Authorization': 'Bearer ' + credentials['HCLOUD_TOKEN']})
        with urllib.request.urlopen(request, timeout=20) as response:
            pricing = json.load(response)['pricing']
        prices = {t['name']: next((float(p['price_hourly']['gross']) for p in t['prices']
                  if p['location'] == data['region']), None) for t in pricing['server_types']}
        if all(prices.get(data[r + '_type']) is not None for r in ('master', 'worker')):
            cost = sum(data[r + 's'] * prices[data[r + '_type']] for r in ('master', 'worker'))
            print(f'Compute estimate: {cost:.4f} {pricing["currency"]}/hour (gross; excludes bootstrap, LB, IPs, snapshots, traffic)')
    else:
        print('Cost estimate unavailable: credentials file is not configured.')
    print('Configuration preview only; no cloud changes. Use --terraform-plan after ignition/image preparation for a provider resource diff.')


def offer_resume(work, args):
    if not (work / '.phases/configured').exists() or (work / '.phases/ready').exists():
        return args
    if '--resume' in args:
        return args
    if (work / '.phases/ignition').exists():
        required = ['ignition/auth/kubeconfig', 'ignition/bootstrap.ign', 'ignition/master.ign', 'ignition/worker.ign']
        if any(not (work / name).is_file() or not (work / name).stat().st_size for name in required):
            raise ConfigError(f'{work}: checkpoints exist but original installation artifacts are missing; recover the original files before resuming')
    overrides = ('--region', '--release', '--masters', '--workers', '--master-type', '--worker-type', '--profile', '--pull-secret-file')
    if any(flag in args for flag in overrides):
        raise ConfigError('installation already started; use --resume without topology/release overrides')
    if not sys.stdin.isatty() or '--yes' in args:
        raise ConfigError('installation already started; use --resume to preserve its original settings and credentials')
    values = read_env(work / '.env')
    print(f'Unfinished {values.get("DEPLOYMENT_TYPE", "okd")} installation: '
          f'{values.get("OPENSHIFT_RELEASE")} · {values.get("TF_VAR_location")} · '
          f'{values.get("TF_VAR_replicas_master")} masters / {values.get("TF_VAR_replicas_worker")} workers', flush=True)
    choice = input('Resume using these saved settings and credentials? [Y/n]: ').strip().lower()
    if choice not in ('', 'y', 'yes'):
        raise ConfigError('cancelled; saved installation files were preserved')
    return [*args, '--resume']


def save_region_selection(config_path, work):
    """Persist a fresh interactive region choice for subsequent lifecycle commands."""
    config_path, work = Path(config_path), Path(work)
    if (work / '.phases/configured').exists():
        raise ConfigError('cannot change the region of a configured cluster')
    values = read_env(work / '.env')
    data = yaml.safe_load(config_path.read_text())
    identity = json.loads((work / 'cluster.json').read_text())
    for key in ('name', 'domain', 'distribution', 'release'):
        if data.get(key, 'okd' if key == 'distribution' else None) != identity.get(key, 'okd' if key == 'distribution' else None):
            raise ConfigError('cluster identity changed during region selection')
    for key, env_key in (('region', 'TF_VAR_location'), ('network_zone', 'TF_VAR_network_zone')):
        value = token(values.get(env_key), r'[a-z0-9-]+', key)
        data[key] = identity[key] = value
    atomic_write(config_path, yaml.safe_dump(data, sort_keys=False))
    atomic_write(work / 'cluster.json', json.dumps(identity, indent=2) + '\n')


def route_distribution(repo, operation, args):
    """Choose the distribution before loading or writing any workspace files."""
    args = list(args)
    if any(flag in args for flag in ('--cluster', '--help', '-h', '--plan')):
        return args
    # Day-two operations use their recorded identity, including unattended teardown.
    recorded_operations = ('--resume', '--terraform-plan', '--restore-snapshot',
                           '--snapshot-list', '--snapshot-cloud-list', '--snapshot-import-template',
                           '--snapshot-import-plan', '--snapshot-import', '--scale', '--rescale',
                           '--autoscale', '--admin', '--monitoring', '--devops', '--devops-components',
                           '--cluster-autoscaler', '--ca-smoke-test', '--defcon')
    if any(flag in args for flag in recorded_operations):
        return args
    interactive = sys.stdin.isatty() and '--yes' not in args
    distribution = None
    if '--distribution' in args:
        index = args.index('--distribution')
        if index + 1 == len(args) or args.count('--distribution') != 1:
            raise ConfigError('--distribution needs one value: okd or openshift')
        distribution = args[index + 1]
    elif interactive:
        print('Choose the cluster distribution before loading its environment:', flush=True)
        print('  1) OKD (community)\n  2) Red Hat OpenShift', flush=True)
        choice = input('Selection [1]: ').strip().lower() or '1'
        distribution = {'1': 'okd', 'okd': 'okd', '2': 'openshift', 'openshift': 'openshift'}.get(choice)
        if distribution is None:
            raise ConfigError('choose 1 (OKD) or 2 (Red Hat OpenShift)')
        args += ['--distribution', distribution]
    else:
        return args
    if distribution not in ('okd', 'openshift'):
        raise ConfigError('--distribution must be okd or openshift')
    candidates = []
    for path in sorted((repo / 'clusters').glob('*.yaml')):
        data = yaml.safe_load(path.read_text())
        if isinstance(data, dict) and data.get('distribution', 'okd') == distribution:
            if operation != 'destroy' or (repo / '.work' / path.stem / 'cluster.json').exists():
                candidates.append(path.stem)
    legacy = repo / '.env'
    legacy_distribution = read_env(legacy).get('DEPLOYMENT_TYPE', 'okd') if legacy.exists() else 'okd'
    # Keep the existing OKD legacy workspace as a routing option; OpenShift uses
    # its own manifest whenever one is configured.
    if distribution == 'okd' and legacy.exists() and legacy_distribution == 'okd':
        candidates.insert(0, 'legacy')
    if not candidates:
        raise ConfigError(f'No {distribution} workspace configured. Copy clusters/{distribution if distribution == "openshift" else "dev"}.yaml.example to clusters/{distribution}.yaml and configure its domain, credentials and release.')
    if len(candidates) == 1:
        selected = candidates[0]
    elif interactive:
        print(f'Choose the {distribution} workspace:', flush=True)
        for number, name in enumerate(candidates, 1):
            print(f'  {number}) {name}', flush=True)
        value = input('Workspace number: ').strip()
        if not value.isdigit() or not 1 <= int(value) <= len(candidates):
            raise ConfigError('invalid workspace selection')
        selected = candidates[int(value) - 1]
    else:
        raise ConfigError('Multiple matching workspaces; specify --cluster NAME explicitly')
    print(f'Selected {"Red Hat OpenShift" if distribution == "openshift" else "OKD"} · workspace {selected}', flush=True)
    if selected != 'legacy':
        args += ['--cluster', selected]
    return args


def choose_deploy_operation(repo, name, args):
    """Choose a local restore set before workspace preparation or cloud access.

    None means cancellation. Existing explicit lifecycle flags never prompt here.
    The child keeps its existing typed restore confirmation and identity checks.
    """
    args = list(args)
    interactive = sys.stdin.isatty() and '--yes' not in args
    routing_only = not args or (len(args) == 2 and args[0] == '--distribution')
    if routing_only and interactive:
        print(f'Choose operation for workspace {name or "legacy"}:', flush=True)
        print('  1) Deploy / continue installation\n  2) Restore a saved cluster snapshot\n  0) Cancel', flush=True)
        choice = input('Operation [1]: ').strip() or '1'
        if choice == '0':
            print('Cancelled. No deployment or restore started.', flush=True)
            return None
        if choice not in ('1', '2'):
            raise ConfigError('choose operation 1, 2 or 0')
        if choice == '2':
            args.append('--restore')
    if '--restore' not in args:
        return args
    if not interactive:
        raise ConfigError('--restore requires an interactive terminal; use --cluster NAME --restore-snapshot ID for an explicit restore')
    # Reject incompatible flags before reading a selection or touching artifacts.
    remaining, distribution = [], None
    index = 0
    while index < len(args):
        flag = args[index]
        if flag == '--restore':
            if args.count(flag) != 1:
                raise ConfigError('--restore may only be specified once')
            index += 1
        elif flag in ('--distribution', '--duration', '--autodestroy-at'):
            if index + 1 >= len(args):
                raise ConfigError(f'{flag} needs a value')
            if flag == '--distribution':
                if distribution is not None:
                    raise ConfigError('--distribution may only be specified once')
                distribution = args[index + 1]
            else:
                remaining += args[index:index + 2]
            index += 2
        elif flag in ('--no-autodestroy', '--snapshot-before-destroy', '--no-snapshot-before-destroy'):
            remaining.append(flag)
            index += 1
        else:
            raise ConfigError(f'--restore uses saved configuration; incompatible option: {flag}')
    work = repo / '.work' / name if name else repo
    if name:
        config = load_config(repo, name)
        domain, recorded_distribution = config['domain'], config.get('distribution', 'okd')
    else:
        if not (work / '.env').exists():
            raise ConfigError('No legacy cluster environment; select a configured --cluster NAME')
        config = read_env(work / '.env')
        domain = config.get('TF_VAR_dns_domain')
        recorded_distribution = config.get('DEPLOYMENT_TYPE', 'okd')
    if distribution is not None and distribution != recorded_distribution:
        raise ConfigError('--distribution must match the selected workspace')
    candidates = []
    other_domains = set()
    store = work / '.cluster-snapshots'
    if not store.is_symlink():
        for path in sorted(store.glob('*/manifest.json')):
            if path.is_symlink() or path.parent.is_symlink() or not re.fullmatch(r'[a-zA-Z0-9_-]{1,80}', path.parent.name):
                continue
            try:
                manifest = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if not isinstance(manifest, dict):
                continue
            if (manifest.get('version'), manifest.get('cluster'), manifest.get('status')) == (1, name or '', 'ready') and manifest.get('domain') != domain:
                other_domains.add(str(manifest.get('domain')))
            if (manifest.get('version'), manifest.get('domain'), manifest.get('cluster'), manifest.get('status')) != (1, domain, name or '', 'ready'):
                continue
            if not isinstance(manifest.get('nodes'), list) or not manifest['nodes']:
                continue
            candidates.append((path.parent.name, len(manifest['nodes'])))
    if not candidates:
        detail = (' Saved snapshots belong to: ' + ', '.join(sorted(other_domains)) + '. Restore the original workspace configuration before proceeding.') if other_domains else ''
        raise ConfigError(f'No completed local snapshots for {name or "legacy"} ({domain}); use --snapshot-list with the correct --cluster.' + detail)
    print(f'Restore snapshots for {name or "legacy"} · {domain}:', flush=True)
    for number, (snapshot, nodes) in enumerate(candidates, 1):
        print(f'  {number}) {snapshot}  ready  {nodes} node(s)', flush=True)
    print('  0) Cancel', flush=True)
    selection = input('Snapshot number (0 cancels): ').strip()
    if selection == '0':
        print('Cancelled. No deployment or restore started.', flush=True)
        return None
    if not selection.isdigit() or not 1 <= int(selection) <= len(candidates):
        raise ConfigError('invalid snapshot selection; no deployment or restore started')
    snapshot = candidates[int(selection) - 1][0]
    print(f'Selected restore: {snapshot} · {domain}. The restore command will request confirmation before provisioning.', flush=True)
    return ['--restore-snapshot', snapshot, *remaining]


def run(repo, operation, args):
    args = route_distribution(repo, operation, args)
    if any(arg in ('--help', '-h') for arg in args):
        clean = list(args)
        if '--cluster' in clean:
            pos = clean.index('--cluster')
            del clean[pos:pos + 2]
        env = dict(os.environ, HCLOUD_OKD4_CONTEXT_DIR=str(repo))
        return subprocess.call(['bash', str(repo / f'{operation}-okd.sh'), *clean], env=env)
    name = None
    if '--cluster' in args:
        index = args.index('--cluster')
        if index + 1 == len(args):
            raise ConfigError('--cluster needs a name')
        name = token(args[index + 1], r'[a-z][a-z0-9-]{0,30}', 'cluster name')
        args = args[:index] + args[index + 2:]
        if '--cluster' in args:
            raise ConfigError('--cluster may only be specified once')
    if '--plan' in args and name:
        if operation != 'deploy' or args != ['--plan']:
            raise ConfigError('--plan uses the cluster YAML; combine it only with --cluster')
        with operation_lock(repo, name):
            preview(repo, name)
        return 0
    with operation_lock(repo, name or 'legacy'):
        if operation == 'deploy':
            args = choose_deploy_operation(repo, name, args)
            if args is None:
                return 0
        env = dict(os.environ)
        if name:
            desired = load_config(repo, name)
            for flag, key in (('--release', 'release'), ('--distribution', 'distribution')):
                if flag in args and (args.index(flag) + 1 == len(args) or args[args.index(flag) + 1] != desired[key]):
                    raise ConfigError(f'{flag} must match the pinned cluster YAML')
            if '--region' in args:
                index = args.index('--region')
                if index + 1 == len(args):
                    raise ConfigError('--region needs a value')
                if (repo / '.work' / name / '.phases/configured').exists() and args[index + 1] != desired['region']:
                    raise ConfigError('cannot change region of a configured cluster')
            work, data = prepare(repo, name, operation, '--resume' in args)
            for key in list(env):
                if key.startswith('TF_VAR_') or key.startswith('TF_CLI_ARGS') or key in ('TF_WORKSPACE', 'TF_DATA_DIR', 'KUBECONFIG'):
                    del env[key]
            env['CLUSTER_ID'] = name
            env['CLUSTER_CONFIG'] = str(repo / 'clusters' / f'{name}.yaml')
            if operation == 'deploy':
                # The manifest supplies defaults; CLI overrides are intentionally explicit.
                defaults = {'--masters': data['masters'], '--workers': data['workers'],
                            '--master-type': data['master_type'], '--worker-type': data['worker_type'],
                            '--region': data['region'], '--release': data['release'], '--duration': data['duration']}
                day_two = any(flag in args for flag in (
                    '--scale', '--rescale', '--rescale-role', '--rescale-type', '--admin', '--monitoring',
                    '--devops', '--devops-components', '--autoscale', '--cluster-autoscaler', '--ca-smoke-test',
                    '--ca-type', '--ca-min', '--ca-max', '--terraform-plan', '--resume',
                    '--restore-snapshot', '--snapshot-list', '--snapshot-cloud-list',
                    '--snapshot-import-template', '--snapshot-import-plan', '--snapshot-import'))
                if not day_two:
                    args = offer_resume(work, args)
                    day_two = '--resume' in args
                if '--scale' in args and '--masters' not in args and '--workers' not in args:
                    args += ['--masters', str(data['masters']), '--workers', str(data['workers'])]
                if not day_two and not (work / '.phases/configured').exists():
                    interactive_setup = sys.stdin.isatty() and '--yes' not in args
                    env['HCLOUD_OKD4_INTERACTIVE_SETUP'] = '1' if interactive_setup else '0'
                    env['HCLOUD_OKD4_SAVE_REGION'] = '1'
                    for flag, value in defaults.items():
                        if interactive_setup and flag in ('--region', '--masters', '--workers', '--master-type', '--worker-type', '--duration'):
                            continue
                        if flag not in args:
                            args += [flag, str(value)]
                    if not interactive_setup and '--profile' not in args:
                        args += ['--profile', '4']
                snapshot_management = any(flag in args for flag in (
                    '--snapshot-list', '--snapshot-cloud-list', '--snapshot-import-template',
                    '--snapshot-import-plan', '--snapshot-import'))
                if not data['autodestroy'] and '--no-autodestroy' not in args and not snapshot_management:
                    args.append('--no-autodestroy')
        else:
            work = repo
            env['CLUSTER_ID'] = ''
        env['HCLOUD_OKD4_CONTEXT_DIR'] = str(work)
        env['REPO_ROOT'] = str(repo)
        env['AUTODESTROY_ID'] = (name or 'legacy') + '-' + hashlib.sha256(str(repo).encode()).hexdigest()[:10]
        (work / 'logs').mkdir(exist_ok=True, mode=0o700)
        # The child inherits the terminal; credentials are never copied to an automatic transcript.
        started = datetime.now(timezone.utc).isoformat()
        child = subprocess.Popen(['bash', str(repo / f'{operation}-okd.sh'), *args], env=env)
        def forward(signum, _frame):
            if child.poll() is None:
                child.send_signal(signum)
        previous_handler = signal.signal(signal.SIGTERM, forward)
        try:
            while True:
                try:
                    result = child.wait()
                    break
                except KeyboardInterrupt:
                    forward(signal.SIGINT, None)
        finally:
            signal.signal(signal.SIGTERM, previous_handler)
        result = result if result >= 0 else 128 - result
        phases = sorted(p.name for p in (work / '.phases').glob('*') if not p.name.endswith('.tmp'))
        atomic_write(work / 'logs/last-operation.json', json.dumps({
            'cluster': name or 'legacy', 'operation': operation, 'started': started,
            'finished': datetime.now(timezone.utc).isoformat(), 'exit_code': result,
            'completed_phases': phases,
        }, indent=2) + '\n')
        if result:
            print(f'{operation} failed for {name or "legacy"} (exit {result}); details: {work / "logs/last-operation.json"}', file=sys.stderr)
        return result


def main():
    os.umask(0o077)
    try:
        if sys.argv[1] == 'env':
            for key, value in read_env(sys.argv[2]).items():
                print(f'export {key}={shlex.quote(value)}')
            return 0
        if sys.argv[1] == 'save-region':
            save_region_selection(sys.argv[2], sys.argv[3])
            return 0
        if sys.argv[1] == 'set-env':
            values = read_env(sys.argv[2])
            values[sys.argv[3]] = sys.argv[4]
            write_env(sys.argv[2], values)
            return 0
        if sys.argv[1] == 'run':
            return run(Path(sys.argv[2]).resolve(), sys.argv[3], sys.argv[4:])
        raise ConfigError('unknown command')
    except (KeyboardInterrupt, EOFError):
        print('\nCancelled.', file=sys.stderr)
        return 130
    except (ConfigError, OSError, ValueError, yaml.YAMLError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
