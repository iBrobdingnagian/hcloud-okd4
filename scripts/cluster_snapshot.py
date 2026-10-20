#!/usr/bin/env python3
"""Offline node snapshots and restore manifests for the selected workspace.

Never deletes servers. Called under cluster_context's lifecycle lock. A failed
snapshot leaves the cluster stopped and the manifest incomplete, blocking destroy.
"""
import argparse
from datetime import datetime, timezone
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
import uuid

from check_state import check as check_state
from cluster_context import read_env, write_env

STORE = '.cluster-snapshots'
RESTORE_VARS = 'terraform/cluster-restore.auto.tfvars.json'


class SnapshotError(ValueError):
    pass


def save(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(data, stream, indent=2)
        stream.write('\n')
    temp.chmod(0o600)
    temp.replace(path)


class Cloud:
    def __init__(self):
        self.token = os.environ.get('HCLOUD_TOKEN')
        if not self.token:
            raise SnapshotError('HCLOUD_TOKEN is required')

    def request(self, path, data=None, method=None):
        req = urllib.request.Request('https://api.hetzner.cloud/v1/' + path,
            data=json.dumps(data).encode() if data is not None else None,
            headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'},
            method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            raise SnapshotError(f'Hetzner {path.split("?")[0]} returned HTTP {exc.code}') from exc

    def list(self, kind):
        result, page = [], 1
        while page:
            data = self.request(f'{kind}?per_page=100&page={page}')
            if not isinstance(data.get(kind), list):
                raise SnapshotError(f'Invalid {kind} response')
            result += data[kind]
            following = data.get('meta', {}).get('pagination', {}).get('next_page')
            if following is not None and (type(following) is not int or following <= page):
                raise SnapshotError('Invalid pagination response')
            page = following
        return result

    def wait(self, action):
        deadline = time.monotonic() + 1800
        while time.monotonic() < deadline:
            current = self.request(f'actions/{action["id"]}')['action']
            if current['status'] == 'success':
                return
            if current['status'] == 'error':
                raise SnapshotError(f'Hetzner action {action["id"]} failed')
            time.sleep(3)
        raise SnapshotError(f'Hetzner action {action["id"]} timed out')


def identity(work):
    env = read_env(work / '.env')
    return env, env['TF_VAR_dns_domain'], os.environ.get('CLUSTER_ID', '')


def selected(servers, domain, cluster):
    result = []
    for server in servers:
        labels = server.get('labels') or {}
        domain_match = server['name'].endswith('.' + domain)
        owner_match = bool(cluster) and labels.get('hcloud-okd4/cluster') == cluster
        if cluster and domain_match and not owner_match:
            raise SnapshotError('Cluster domain has servers with conflicting ownership')
        if owner_match and not domain_match:
            raise SnapshotError('Cluster ownership label has a conflicting domain')
        if domain_match or owner_match:
            result.append(server)
    return sorted(result, key=lambda server: server['name'])


def state_servers(work, domain, cluster, allow_missing=False):
    path = work / 'terraform/terraform.tfstate'
    if allow_missing and not path.exists():
        return {}
    check_state(path, domain, cluster)
    state = json.loads(path.read_text())
    servers = {}
    for resource in state['resources']:
        if resource.get('mode') == 'data':
            continue
        if resource['type'] in ('hcloud_volume', 'hcloud_primary_ip') and resource.get('instances'):
            raise SnapshotError('Managed volumes or Primary IP resources require a separate backup/retention plan')
        if resource['type'] == 'hcloud_server':
            for instance in resource.get('instances', []):
                node = instance['attributes']
                servers[node['name']] = int(node['id'])
    return servers


def bundle_files(work, destination):
    # Fixed paths only; no archives or executable files are unpacked from manifests.
    for name in ('ignition', 'config', 'install-config.yaml', '.phases'):
        source = work / name
        if source.is_symlink() or any(p.is_symlink() for p in source.rglob('*')):
            raise SnapshotError(f'Symlinks are not supported in snapshot artifacts: {name}')
        target = destination / name
        if target.is_symlink() or any(p.is_symlink() for p in target.rglob('*')):
            raise SnapshotError(f'Restore destination contains symlinks: {name}')
        if source.is_dir():
            shutil.copytree(source, destination / name, dirs_exist_ok=True)
        elif source.is_file():
            destination.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copy2(source, destination / name)
        target = destination / name
        if target.exists():
            target.chmod(0o700 if target.is_dir() else 0o600)
            for path in target.rglob('*'):
                path.chmod(0o700 if path.is_dir() else 0o600)


def create(work, cloud):
    env, domain, cluster = identity(work)
    expected = state_servers(work, domain, cluster)
    nodes = selected(cloud.list('servers'), domain, cluster)
    if not nodes or {s['name']: s['id'] for s in nodes} != expected:
        raise SnapshotError('Live servers must exactly match Terraform; remove autoscaled/unmanaged nodes first')
    if not (work / '.phases/ready').exists() or not (work / 'ignition/auth/kubeconfig').is_file():
        raise SnapshotError('Snapshot requires a completed installation and its original kubeconfig')
    for node in nodes:
        if not re.fullmatch(r'(master|worker)[0-9]{2,}\.' + re.escape(domain), node['name']):
            raise SnapshotError('Only installed master/worker nodes can be snapshotted')
        if node.get('volumes') or node.get('private_net') or (node.get('labels') or {}).get('hcloud/node-group'):
            raise SnapshotError('Attached volumes, private node networks, or autoscaler pools are not supported by node-disk restore')
        if node['status'] not in ('running', 'off'):
            raise SnapshotError('Wait for every node to be running or off before snapshotting')
        for family in ('ipv4', 'ipv6'):
            if not (node.get('public_net', {}).get(family) or {}).get('id'):
                raise SnapshotError('Restore requires retained IPv4 and IPv6 Primary IP IDs')
    # Validate all topology and artifact assumptions before stopping any node.
    for role in ('master', 'worker'):
        names = sorted(n['name'] for n in nodes if n['name'].startswith(role))
        count = int(env['TF_VAR_replicas_' + role])
        if names != [f'{role}{i:02d}.{domain}' for i in range(1, count + 1)]:
            raise SnapshotError('Configured node counts do not match the live topology')
    name = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8]
    if (work / STORE).is_symlink():
        raise SnapshotError('Snapshot store must not be a symlink')
    directory = work / STORE / name
    directory.mkdir(parents=True, mode=0o700)
    directory.parent.chmod(0o700)
    bundle_files(work, directory / 'artifacts')
    shutil.copy2(work / 'terraform/terraform.tfstate', directory / 'terraform-state-before-delete.json')
    (directory / 'terraform-state-before-delete.json').chmod(0o600)
    config = {k: v for k, v in env.items() if k.startswith('TF_VAR_') or k in ('OPENSHIFT_RELEASE', 'DEPLOYMENT_TYPE')}
    manifest = {'version': 1, 'id': name, 'domain': domain, 'cluster': cluster,
                'status': 'creating', 'created': datetime.now(timezone.utc).isoformat(),
                'config': config, 'nodes': []}
    path = directory / 'manifest.json'
    save(path, manifest)
    try:
        # Stop workers before the control plane; no snapshots until ALL nodes are off.
        for node in sorted(nodes, key=lambda n: not n['name'].startswith('worker')):
            if node['status'] == 'running':
                cloud.wait(cloud.request(f'servers/{node["id"]}/actions/shutdown', {})['action'])
        deadline = time.monotonic() + 300
        while True:
            stopped = [cloud.request(f'servers/{n["id"]}')['server']['status'] == 'off' for n in nodes]
            if all(stopped):
                break
            if time.monotonic() >= deadline:
                raise SnapshotError('Graceful shutdown timed out; no forced poweroff or deletion was performed')
            time.sleep(3)
        for node in nodes:
            print('Snapshotting ' + node['name'], file=sys.stderr, flush=True)
            response = cloud.request(f'servers/{node["id"]}/actions/create_image', {
                'type': 'snapshot', 'description': f'{"RH OpenShift" if env.get("DEPLOYMENT_TYPE", "okd") == "openshift" else "OKD"} {name} {node["name"]}',
                'labels': {'hcloud-okd4/snapshot': name,
                           'hcloud-okd4/node': node['name'].split('.')[0]}})
            image_id = response['image']['id']
            record = {'name': node['name'], 'image': image_id,
                      'server_type': node['server_type']['name'],
                      'ipv4': node['public_net']['ipv4']['id'],
                      'ipv6': node['public_net']['ipv6']['id'],
                      'ipv4_address': node['public_net']['ipv4']['ip'],
                      'ipv6_address': node['public_net']['ipv6']['ip']}
            manifest['nodes'].append(record)
            save(path, manifest)  # Retain image IDs even when an action fails.
            cloud.wait(response['action'])
            image = cloud.request(f'images/{image_id}')['image']
            if image['status'] != 'available' or image['type'] != 'snapshot':
                raise SnapshotError('Snapshot image is not available')
            protection = cloud.request(f'images/{image_id}/actions/change_protection', {'delete': True})
            cloud.wait(protection['action'])
        for node in manifest['nodes']:
            for family in ('ipv4', 'ipv6'):
                cloud.request(f'primary_ips/{node[family]}', {'auto_delete': False}, method='PUT')
                ip = cloud.request(f'primary_ips/{node[family]}')['primary_ip']
                if ip['auto_delete']:
                    raise SnapshotError('Primary IP retention could not be verified')
        manifest['status'] = 'ready'
        save(path, manifest)
    except BaseException:
        manifest['status'] = 'failed'
        save(path, manifest)
        print(f'Snapshot incomplete: {path}. Teardown blocked. Nodes may be stopped; inspect before restarting.', file=sys.stderr)
        raise
    print(f'Snapshot set ready: {name}. Keep {directory} and retained Primary IPs for restore.', file=sys.stderr)
    return name


def read_manifest(work, name):
    if not re.fullmatch(r'[a-zA-Z0-9_-]{1,80}', name):
        raise SnapshotError('Use a snapshot ID from --snapshot-list')
    directory = work / STORE / name
    if directory.parent.is_symlink() or directory.is_symlink() or (directory / 'manifest.json').is_symlink():
        raise SnapshotError('Snapshot directory must not be a symlink')
    data = json.loads((directory / 'manifest.json').read_text())
    env, domain, cluster = identity(work)
    if (data.get('version'), data.get('domain'), data.get('cluster'), data.get('status')) != (1, domain, cluster, 'ready'):
        raise SnapshotError('Snapshot is incomplete or belongs to a different cluster')
    if data['config'].get('OPENSHIFT_RELEASE') != env.get('OPENSHIFT_RELEASE'):
        raise SnapshotError('Restore must use the original deployment release')
    for key in ('TF_VAR_dns_domain', 'TF_VAR_dns_zone_id', 'TF_VAR_cluster_id',
                'TF_VAR_location', 'TF_VAR_network_zone', 'TF_VAR_network_cidr',
                'TF_VAR_subnet_cidr', 'TF_VAR_lb_subnet_cidr'):
        if data['config'].get(key, '') != env.get(key, ''):
            raise SnapshotError(f'Snapshot identity setting differs: {key}')
    return directory, data


def image_identity(image):
    """Immutable image provenance used by imports instead of changing labels."""
    source = image.get('created_from') or {}
    return {'created': image.get('created'),
            'source_server_id': source.get('id'), 'source_server_name': source.get('name')}


def verify_image(node, image, manifest):
    if image['status'] != 'available' or image['type'] != 'snapshot':
        raise SnapshotError('Snapshot image is missing or unavailable')
    if manifest.get('origin') == 'import':
        if not node.get('image_identity') or image_identity(image) != node['image_identity']:
            raise SnapshotError('Imported image provenance no longer matches the reviewed record')
    else:
        labels = image.get('labels') or {}
        if labels.get('hcloud-okd4/snapshot') != manifest['id'] or labels.get('hcloud-okd4/node') != node['name'].split('.')[0]:
            raise SnapshotError('Snapshot image ownership does not match manifest')


def discover(work, cloud):
    recorded = {}
    for path in (work / STORE).glob('*/manifest.json'):
        data = json.loads(path.read_text())
        if data.get('status') == 'ready':
            for node in data.get('nodes', []):
                recorded.setdefault(node['image'], []).append(path.parent.name)
    return [{'image': image['id'], 'description': image.get('description'),
             'status': image['status'], 'created': image.get('created'),
             'source': image.get('created_from'),
             'recorded_sets': recorded.get(image['id'], []),
             'labels': image.get('labels') or {}}
            for image in cloud.list('images') if image['type'] == 'snapshot']


def import_template(work, path):
    env, domain, cluster = identity(work)
    nodes = [{'name': f'{role}{i:02d}.{domain}', 'image': 0, 'ipv4': 0, 'ipv6': 0}
             for role in ('master', 'worker')
             for i in range(1, int(env['TF_VAR_replicas_' + role]) + 1)]
    spec = {'id': 'import-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'),
            'source_state': 'terraform/terraform.tfstate', 'config_file': '.env',
            'artifacts_dir': '.', 'consistent_shutdown_confirmed': False,
            'matching_artifacts_confirmed': False, 'nodes': nodes}
    # Never overwrite an operator's reviewed plan.
    with Path(path).open('x') as stream:
        os.chmod(path, 0o600)
        json.dump(spec, stream, indent=2)
        stream.write('\n')


def review_import(work, spec_path, cloud):
    """GET-only preflight. Does not modify manifests, credentials or cloud objects."""
    spec = json.loads(Path(spec_path).read_text())
    name = spec.get('id', '')
    if not re.fullmatch(r'import-[a-zA-Z0-9_-]{1,70}', name):
        raise SnapshotError('Imported set ID must start with import- and contain only letters, numbers, _ or -')
    if (work / STORE).is_symlink() or (work / STORE / name).exists():
        raise SnapshotError('Snapshot set already exists or snapshot store is a symlink; no overwrite allowed')
    if spec.get('consistent_shutdown_confirmed') is not True or spec.get('matching_artifacts_confirmed') is not True:
        raise SnapshotError('Confirm in the review file that all nodes were snapshotted while stopped and artifacts match that cluster incarnation')
    current, domain, cluster = identity(work)
    config = read_env(Path(spec['config_file']))
    for key in ('OPENSHIFT_RELEASE', 'TF_VAR_dns_domain', 'TF_VAR_dns_zone_id',
                'TF_VAR_cluster_id', 'TF_VAR_location', 'TF_VAR_network_zone',
                'TF_VAR_network_cidr', 'TF_VAR_subnet_cidr', 'TF_VAR_lb_subnet_cidr'):
        if config.get(key, '') != current.get(key, ''):
            raise SnapshotError(f'Original snapshot configuration differs from this workspace: {key}')
    state_path = Path(spec['source_state'])
    check_state(state_path, domain, cluster)
    state = json.loads(state_path.read_text())
    originals = {}
    for resource in state['resources']:
        if resource.get('mode') == 'data':
            continue
        if resource['type'] in ('hcloud_volume', 'hcloud_primary_ip') and resource.get('instances'):
            raise SnapshotError('Attached/managed volumes or managed Primary IP resources need separate recovery')
        if resource['type'] == 'hcloud_server':
            if resource.get('instances') and resource.get('module') not in ('module.master', 'module.worker'):
                raise SnapshotError('Source state must contain only installed Terraform master/worker servers')
            for instance in resource.get('instances', []):
                node = instance['attributes']
                if node.get('network') or node.get('volume_ids'):
                    raise SnapshotError('Private node networks or attached volumes cannot be imported')
                originals[node['name']] = node
    expected = {f'{role}{i:02d}.{domain}' for role in ('master', 'worker')
                for i in range(1, int(config['TF_VAR_replicas_' + role]) + 1)}
    entries = spec.get('nodes', [])
    if (int(config['TF_VAR_replicas_master']) not in (1, 3, 5) or not expected
            or set(originals) != expected or len(entries) != len(expected)
            or {n['name'] for n in entries} != expected):
        raise SnapshotError('A complete snapshot mapping and original state for every configured node are required')
    artifacts = Path(spec['artifacts_dir'])
    for filename in ('ignition/auth/kubeconfig', 'ignition/master.ign', 'ignition/worker.ign'):
        if not (artifacts / filename).is_file():
            raise SnapshotError('Matching original installation artifacts are missing: ' + filename)
    import yaml
    kube = yaml.safe_load((artifacts / 'ignition/auth/kubeconfig').read_text())
    from cluster_access import load_balancer_ip, selected_cluster, validate_identity
    try:
        endpoint = selected_cluster(kube).get('server')
        address = (None if endpoint == 'https://api.' + domain + ':6443'
                   else load_balancer_ip(state, domain))
        validate_identity(kube, domain, address)
    except ValueError as exc:
        raise SnapshotError('Original kubeconfig does not select this cluster domain') from exc
    from validate_ignition import validate
    for role in ('master', 'worker'):
        validate(artifacts / f'ignition/{role}.ign')
    live = {n['name']: n for n in selected(cloud.list('servers'), domain, cluster)}
    if any(node.get('volumes') or node.get('private_net') for node in live.values()):
        raise SnapshotError('Live cluster has attached volumes or private node networks; node-disk-only import is unsupported')
    manifest = {'version': 1, 'id': name, 'domain': domain, 'cluster': cluster,
                'status': 'ready', 'origin': 'import',
                'created': datetime.now(timezone.utc).isoformat(),
                'consistency': 'operator-confirmed cold snapshot set and matching artifacts',
                'config': {k: v for k, v in config.items() if k.startswith('TF_VAR_') or k in ('OPENSHIFT_RELEASE', 'DEPLOYMENT_TYPE')},
                'nodes': []}
    seen_images, seen_ips = set(), set()
    for entry in entries:
        original = originals[entry['name']]
        for key in ('image', 'ipv4', 'ipv6'):
            if type(entry.get(key)) is not int or entry[key] <= 0:
                raise SnapshotError('Replace each image and Primary IP placeholder with a positive integer ID')
        if entry['image'] in seen_images or any(entry[k] in seen_ips for k in ('ipv4', 'ipv6')) or entry['ipv4'] == entry['ipv6']:
            raise SnapshotError('Each node needs its own distinct image and Primary IPs')
        seen_images.add(entry['image']); seen_ips.update([entry['ipv4'], entry['ipv6']])
        image = cloud.request(f'images/{entry["image"]}')['image']
        provenance = image_identity(image)
        if (image['type'] != 'snapshot' or image['status'] != 'available'
                or not provenance['created'] or provenance['source_server_id'] != int(original['id'])
                or provenance['source_server_name'] != entry['name']):
            raise SnapshotError('Image is unavailable or was not captured from the server in the original Terraform state')
        if image.get('architecture', 'x86') != 'x86':
            raise SnapshotError('Only x86 node snapshots are supported by this deployment')
        labels = image.get('labels') or {}
        if labels.get('hcloud-okd4/node', entry['name'].split('.')[0]) != entry['name'].split('.')[0]:
            raise SnapshotError('Snapshot node label conflicts with original server')
        node = {k: entry[k] for k in ('name', 'image', 'ipv4', 'ipv6')}
        node.update(server_type=original['server_type'], image_identity=provenance)
        for family, original_key in [('ipv4', 'ipv4_address'), ('ipv6', 'ipv6_network')]:
            ip = cloud.request(f'primary_ips/{entry[family]}')['primary_ip']
            if (ip.get('type') != family or ip.get('auto_delete') is not False
                    or ipaddress.ip_network(ip['ip'], strict=False) != ipaddress.ip_network(original[original_key], strict=False)):
                raise SnapshotError('Original Primary IP is missing, different, or not retained (auto_delete must be false)')
            assignee = (live.get(entry['name']) or {}).get('id')
            if ip.get('assignee_id') != assignee:
                raise SnapshotError('Primary IP is assigned to another server')
            node[family + '_address'] = ip['ip']
        manifest['nodes'].append(node)
    return manifest, artifacts, state_path


def import_existing(work, spec_path, cloud):
    manifest, artifacts, source_state = review_import(work, spec_path, cloud)
    directory = work / STORE / manifest['id']
    directory.mkdir(parents=True, mode=0o700)
    directory.parent.chmod(0o700)
    # Publish ready only after local artifacts have been copied successfully.
    manifest['status'] = 'importing'
    save(directory / 'manifest.json', manifest)
    try:
        bundle_files(artifacts, directory / 'artifacts')
        shutil.copy2(source_state, directory / 'terraform-state-before-delete.json')
        (directory / 'terraform-state-before-delete.json').chmod(0o600)
        manifest['status'] = 'ready'
        save(directory / 'manifest.json', manifest)
    except BaseException:
        manifest['status'] = 'failed'
        save(directory / 'manifest.json', manifest)
        raise
    return manifest['id']


def prepare_restore(work, name, cloud):
    directory, manifest = read_manifest(work, name)
    env, domain, cluster = identity(work)
    nodes = manifest['nodes']
    if not nodes or len({n['name'] for n in nodes}) != len(nodes):
        raise SnapshotError('Invalid snapshot node set')
    restore_nodes = {n['name']: {k: n[k] for k in ('image', 'ipv4', 'ipv6')} for n in nodes}
    state = state_servers(work, domain, cluster, allow_missing=True)
    live = selected(cloud.list('servers'), domain, cluster)
    pending_path = work / 'logs/restore-snapshot.json'
    pending = json.loads(pending_path.read_text()) if pending_path.exists() else {}
    variables = work / RESTORE_VARS
    retry = (pending == {'id': name, 'status': 'prepared'} and variables.exists()
             and json.loads(variables.read_text()) == {'restore_nodes': restore_nodes})
    if state or live:
        if not retry or {n['name']: n['id'] for n in live} != state or set(state) - set(restore_nodes):
            raise SnapshotError('Cluster servers already exist; only an exact interrupted restore can be retried')
        for server in live:
            if (server.get('image') or {}).get('id') != restore_nodes[server['name']]['image']:
                raise SnapshotError('Existing node is not from this snapshot; refusing replacement')
    assigned = {n['name']: n['id'] for n in live}
    for node in nodes:
        if not re.fullmatch(r'(master|worker)[0-9]{2,}\.' + re.escape(domain), node['name']):
            raise SnapshotError('Invalid snapshot node name')
        image = cloud.request(f'images/{int(node["image"])}')['image']
        verify_image(node, image, manifest)
        for family in ('ipv4', 'ipv6'):
            try:
                ip = cloud.request(f'primary_ips/{int(node[family])}')['primary_ip']
            except SnapshotError as exc:
                if isinstance(exc.__cause__, urllib.error.HTTPError) and exc.__cause__.code == 404:
                    raise SnapshotError(
                        f'Restore blocked: original {family} Primary IP {node[family]} '
                        f'({node[family + "_address"]}) for {node["name"]} no longer exists in this project. '
                        'The disk snapshot alone is insufficient for this same-IP restore. '
                        'Do not replace the saved IP IDs with different addresses. '
                        'Check the original Hetzner project/token and whether the retained IPs were deleted; '
                        'no restore resources have been provisioned.') from exc
                raise
            if ip.get('assignee_id') != assigned.get(node['name']) or ip.get('auto_delete') or ipaddress.ip_network(ip['ip'], strict=False) != ipaddress.ip_network(node[family + '_address'], strict=False):
                raise SnapshotError('Retained Primary IP is assigned, unprotected, or changed')
    # Preserve current credentials, but restore the original deployment settings.
    for key, value in manifest['config'].items():
        if key.startswith('TF_VAR_') or key in ('OPENSHIFT_RELEASE', 'DEPLOYMENT_TYPE'):
            env[key] = value
    for role in ('master', 'worker'):
        role_nodes = sorted((n for n in nodes if n['name'].startswith(role)), key=lambda n: n['name'])
        if [n['name'] for n in role_nodes] != [f'{role}{i:02d}.{domain}' for i in range(1,len(role_nodes)+1)]:
            raise SnapshotError('Snapshot node indices must be contiguous')
        env['TF_VAR_replicas_' + role] = str(len(role_nodes))
        env['TF_VAR_server_types_' + role] = ','.join(n['server_type'] for n in role_nodes)
    if int(env['TF_VAR_replicas_master']) not in (1, 3, 5):
        raise SnapshotError('Invalid control-plane count in snapshot')
    if not (directory / 'artifacts/ignition/auth/kubeconfig').is_file():
        raise SnapshotError('Snapshot is missing its original installation artifacts')
    bundle_files(directory / 'artifacts', work)
    (work / '.phases/ready').unlink(missing_ok=True)
    write_env(work / '.env', env)
    save(work / RESTORE_VARS, {'restore_nodes': restore_nodes})
    save(work / 'logs/restore-snapshot.json', {'id': name, 'status': 'prepared'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('create', 'prepare-restore', 'list', 'discover', 'import-template', 'import-plan', 'import'))
    parser.add_argument('snapshot', nargs='?')
    args = parser.parse_args()
    work = Path.cwd()
    if args.operation == 'list':
        for path in sorted((work / STORE).glob('*/manifest.json')):
            data = json.loads(path.read_text())
            print(f'{path.parent.name}  {data.get("status")}  {data.get("domain")}  {len(data.get("nodes", []))} node(s)')
    elif args.operation == 'discover':
        print(json.dumps(discover(work, Cloud()), indent=2))
    elif args.operation == 'import-template' and args.snapshot:
        import_template(work, args.snapshot)
        print('Review file created. Fill in IDs, original state/config/artifacts paths, and the two explicit confirmations.')
    elif args.operation == 'import-plan' and args.snapshot:
        manifest, _, _ = review_import(work, args.snapshot, Cloud())
        print(json.dumps({k: manifest[k] for k in ('id', 'domain', 'cluster', 'consistency', 'nodes')}, indent=2))
        print('Review only: no cloud resources or local snapshot records were changed.')
    elif args.operation == 'import' and args.snapshot:
        manifest, _, _ = review_import(work, args.snapshot, Cloud())
        print(f'Record {len(manifest["nodes"])} existing node image(s) for {manifest["domain"]} as {manifest["id"]}.')
        if input('Type "import" to record this set (no restore will run): ').strip() != 'import':
            raise SnapshotError('Import cancelled')
        print('Imported snapshot set: ' + import_existing(work, args.snapshot, Cloud()))
    elif args.operation == 'create':
        create(work, Cloud())
    elif args.snapshot:
        prepare_restore(work, args.snapshot, Cloud())
    else:
        parser.error('snapshot ID is required')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, EOFError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
