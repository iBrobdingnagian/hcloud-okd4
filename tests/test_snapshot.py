"""Snapshot lifecycle tests use an in-memory Hetzner double; no cloud writes."""
import copy
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import cluster_snapshot as snapshots
from cluster_context import write_env, read_env


class FakeCloud:
    def __init__(self, nodes):
        self.nodes = copy.deepcopy(nodes)
        self.images = {}
        self.ips = {}
        self.calls = []
        self.fail_image = False
        self.next_image = 100
        for node in nodes:
            for family in ('ipv4', 'ipv6'):
                ip = node['public_net'][family]
                self.ips[ip['id']] = dict(ip, auto_delete=True, assignee_id=node['id'])

    def list(self, kind):
        if kind == 'servers':
            return copy.deepcopy(self.nodes)
        assert kind == 'images'
        return copy.deepcopy(list(self.images.values()))

    def wait(self, action):
        if action.get('fail'):
            raise snapshots.SnapshotError('snapshot failed')

    def request(self, path, data=None, method=None):
        self.calls.append((path, data, method))
        parts = path.split('/')
        kind, number = parts[:2]
        number = int(number)
        if kind == 'servers':
            node = next(n for n in self.nodes if n['id'] == number)
            if len(parts) == 2:
                return {'server': copy.deepcopy(node)}
            if parts[-1] == 'shutdown':
                node['status'] = 'off'
                return {'action': {'id': number}}
            if parts[-1] == 'create_image':
                assert all(n['status'] == 'off' for n in self.nodes)
                self.next_image += 1
                self.images[self.next_image] = {'id': self.next_image, 'status': 'available',
                                               'type': 'snapshot', 'labels': data['labels']}
                return {'image': self.images[self.next_image], 'action': {'id': number, 'fail': self.fail_image}}
        if kind == 'images':
            if len(parts) == 2:
                return {'image': self.images[number]}
            return {'action': {'id': number}}
        if kind == 'primary_ips':
            if data:
                self.ips[number].update(data)
            return {'primary_ip': self.ips[number]}
        raise AssertionError(path)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.domain = 'dev.example.com'
        self.env = {'TF_VAR_dns_domain': self.domain, 'TF_VAR_dns_zone_id': 'zone',
                    'TF_VAR_cluster_id': 'dev', 'OPENSHIFT_RELEASE': '4.20.0-okd-scos.9',
                    'TF_VAR_replicas_master': '1', 'TF_VAR_replicas_worker': '1',
                    'HCLOUD_TOKEN': 'original-secret'}
        write_env(self.work / '.env', self.env)
        (self.work / 'terraform').mkdir()
        (self.work / 'ignition/auth').mkdir(parents=True)
        (self.work / 'ignition/auth/kubeconfig').write_text('original identity')
        (self.work / '.phases').mkdir()
        for phase in ('configured', 'ready', 'bootstrap-complete'):
            (self.work / '.phases' / phase).touch()
        self.nodes = []
        for index, role in enumerate(('master', 'worker'), 1):
            self.nodes.append({'id': index, 'name': f'{role}01.{self.domain}', 'status': 'running',
                'server_type': {'name': 'cpx41'}, 'labels': {'hcloud-okd4/cluster': 'dev'},
                'volumes': [], 'private_net': [],
                'public_net': {'ipv4': {'id': index * 10, 'ip': f'192.0.2.{index}'},
                               'ipv6': {'id': index * 10 + 1, 'ip': f'2001:db8:{index}::/64'}}})
        self.state(self.nodes)
        self.cloud = FakeCloud(self.nodes)
        context = patch.dict(os.environ, {'CLUSTER_ID': 'dev'})
        context.start()
        self.addCleanup(context.stop)

    def state(self, nodes):
        state = {'resources': [{'type': 'hcloud_server', 'mode': 'managed',
                   'instances': [{'attributes': {'id': str(n['id']), 'name': n['name'], 'labels': n['labels']}} for n in nodes]}]}
        (self.work / 'terraform/terraform.tfstate').write_text(json.dumps(state))

    def create(self):
        return snapshots.create(self.work, self.cloud)

    def deleted(self):
        self.cloud.nodes = []
        for ip in self.cloud.ips.values():
            ip['assignee_id'] = None
        self.state([])

    def test_cold_snapshots_retain_ips_and_restore_identity_without_credentials_rollback(self):
        name = self.create()
        manifest = self.work / snapshots.STORE / name / 'manifest.json'
        data = json.loads(manifest.read_text())
        self.assertEqual(data['status'], 'ready')
        self.assertEqual(len(data['nodes']), 2)
        self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('HCLOUD_TOKEN', data['config'])
        shutdowns = [path for path, _, _ in self.cloud.calls if path.endswith('/shutdown')]
        self.assertEqual(shutdowns, ['servers/2/actions/shutdown', 'servers/1/actions/shutdown'])
        self.assertTrue(all(not ip['auto_delete'] for ip in self.cloud.ips.values()))
        self.deleted()
        self.env['HCLOUD_TOKEN'] = 'rotated-secret'
        write_env(self.work / '.env', self.env)
        # Unrelated workspace file modes must never be changed during restore.
        executable = self.work / 'deploy-okd.sh'
        executable.write_text('#!/bin/bash\n')
        executable.chmod(0o755)
        (self.work / 'ignition/auth/kubeconfig').write_text('wrong identity')
        snapshots.prepare_restore(self.work, name, self.cloud)
        self.assertEqual((self.work / 'ignition/auth/kubeconfig').read_text(), 'original identity')
        self.assertEqual(read_env(self.work / '.env')['HCLOUD_TOKEN'], 'rotated-secret')
        self.assertEqual(executable.stat().st_mode & 0o777, 0o755)
        self.assertFalse((self.work / '.phases/ready').exists())
        variables = json.loads((self.work / snapshots.RESTORE_VARS).read_text())
        self.assertEqual(variables['restore_nodes'][f'master01.{self.domain}'],
                         {'image': 101, 'ipv4': 10, 'ipv6': 11})

    def test_failed_snapshot_never_produces_restorable_manifest_or_deletes_servers(self):
        self.cloud.fail_image = True
        with self.assertRaises(snapshots.SnapshotError):
            self.create()
        path = next((self.work / snapshots.STORE).glob('*/manifest.json'))
        self.assertEqual(json.loads(path.read_text())['status'], 'failed')
        self.assertTrue(all(method != 'DELETE' for _, _, method in self.cloud.calls))
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.read_manifest(self.work, path.parent.name)

    def test_unsupported_storage_network_or_unmanaged_nodes_fail_before_shutdown(self):
        for field, value in [('volumes', [123]), ('private_net', [{'ip': '10.0.0.2'}])]:
            with self.subTest(field=field):
                self.cloud.nodes[0][field] = value
                with self.assertRaises(snapshots.SnapshotError):
                    self.create()
                self.assertFalse(self.cloud.calls)
                self.cloud.nodes[0][field] = []
        self.cloud.nodes.append(dict(self.nodes[1], id=99, name='worker-asc.dev.example.com'))
        with self.assertRaises(snapshots.SnapshotError):
            self.create()
        self.assertFalse(self.cloud.calls)

    def test_restore_refuses_live_cluster_wrong_identity_release_and_missing_ip(self):
        name = self.create()
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.prepare_restore(self.work, name, self.cloud)
        self.deleted()
        self.env['OPENSHIFT_RELEASE'] = '4.21'
        write_env(self.work / '.env', self.env)
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.prepare_restore(self.work, name, self.cloud)
        self.env['OPENSHIFT_RELEASE'] = '4.20.0-okd-scos.9'
        write_env(self.work / '.env', self.env)
        self.cloud.ips[10]['assignee_id'] = 999
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.prepare_restore(self.work, name, self.cloud)
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.read_manifest(self.work, '../escape')
        with patch.dict(os.environ, {'CLUSTER_ID': 'another'}), self.assertRaises(snapshots.SnapshotError):
            snapshots.read_manifest(self.work, name)

    def test_retry_is_scoped_to_exact_incomplete_restore(self):
        name = self.create()
        self.deleted()
        snapshots.prepare_restore(self.work, name, self.cloud)
        node = copy.deepcopy(self.nodes[0])
        node.update(id=99, image={'id': 101})
        self.cloud.nodes = [node]
        self.cloud.ips[10]['assignee_id'] = 99
        self.cloud.ips[11]['assignee_id'] = 99
        self.state([node])
        snapshots.prepare_restore(self.work, name, self.cloud)
        node['image']['id'] = 999
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.prepare_restore(self.work, name, self.cloud)

    def test_shell_snapshot_failure_aborts_before_teardown(self):
        script = '''
set -euo pipefail
. "$REPO_ROOT/functions/snapshots.sh"
err() { echo "$*" >&2; exit 1; }
oc() { return 0; }
assert_cluster_context() { return 0; }
verify_cluster_health() { return 0; }
python3() { return 1; }
snapshot_before_destroy
touch deletion-started
'''
        result = subprocess.run(['bash', '-c', script], cwd=self.work,
                                env=dict(os.environ, REPO_ROOT=str(ROOT)), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('infrastructure has NOT been deleted', result.stderr)
        self.assertFalse((self.work / 'deletion-started').exists())

    def import_spec(self):
        state = {'resources': []}
        entries = []
        for index, node in enumerate(self.nodes, 1):
            role = node['name'].split('01.')[0]
            state['resources'].append({'type': 'hcloud_server', 'mode': 'managed',
                'module': 'module.' + role, 'instances': [{'attributes': {
                    'id': str(node['id']), 'name': node['name'], 'labels': node['labels'],
                    'server_type': 'cpx41', 'ipv4_address': node['public_net']['ipv4']['ip'],
                    'ipv6_network': node['public_net']['ipv6']['ip'], 'network': []}}]})
            image = 200 + index
            self.cloud.images[image] = {'id': image, 'status': 'available', 'type': 'snapshot',
                'created': '2026-10-18T00:00:00Z', 'architecture': 'x86', 'labels': {},
                'created_from': {'id': node['id'], 'name': node['name']}}
            entries.append({'name': node['name'], 'image': image,
                            'ipv4': node['public_net']['ipv4']['id'], 'ipv6': node['public_net']['ipv6']['id']})
            for family in ('ipv4', 'ipv6'):
                self.cloud.ips[node['public_net'][family]['id']].update(type=family, auto_delete=False)
        original = self.work / 'original.tfstate'
        original.write_text(json.dumps(state))
        (self.work / 'ignition/auth/kubeconfig').write_text(json.dumps({
            'current-context': 'admin', 'contexts': [{'name': 'admin', 'context': {'cluster': 'original'}}],
            'clusters': [{'name': 'original', 'cluster': {'server': 'https://api.' + self.domain + ':6443'}}]}))
        for role in ('master', 'worker'):
            (self.work / f'ignition/{role}.ign').write_text('{"ignition":{"version":"3.0.0"}}')
        spec = {'id': 'import-reviewed', 'source_state': str(original),
                'config_file': str(self.work / '.env'), 'artifacts_dir': str(self.work),
                'consistent_shutdown_confirmed': True, 'matching_artifacts_confirmed': True, 'nodes': entries}
        path = self.work / 'snapshot-import.json'
        path.write_text(json.dumps(spec))
        return path, spec

    def test_unlabelled_existing_images_can_be_reviewed_imported_and_restored_without_cloud_writes(self):
        path, spec = self.import_spec()
        manifest, _, _ = snapshots.review_import(self.work, path, self.cloud)
        self.assertEqual(manifest['origin'], 'import')
        self.assertFalse((self.work / snapshots.STORE).exists())
        self.assertTrue(all(data is None and method is None for _, data, method in self.cloud.calls))
        name = snapshots.import_existing(self.work, path, self.cloud)
        self.assertEqual(name, 'import-reviewed')
        recorded = json.loads((self.work / snapshots.STORE / name / 'manifest.json').read_text())
        self.assertNotIn('HCLOUD_TOKEN', recorded['config'])
        self.assertEqual(recorded['status'], 'ready')
        inventory = snapshots.discover(self.work, self.cloud)
        self.assertEqual(inventory[0]['recorded_sets'], ['import-reviewed'])
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.import_existing(self.work, path, self.cloud)
        # Import can record an existing cluster, but restore must not replace it.
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.prepare_restore(self.work, name, self.cloud)
        self.deleted()
        snapshots.prepare_restore(self.work, name, self.cloud)
        self.assertEqual(json.loads((self.work / snapshots.RESTORE_VARS).read_text())['restore_nodes'][self.nodes[0]['name']]['image'], 201)
        self.cloud.images[201]['created_from']['id'] = 999
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.prepare_restore(self.work, name, self.cloud)
        self.assertTrue(all(data is None and method is None for _, data, method in self.cloud.calls))

    def test_import_rejects_unconfirmed_incomplete_or_wrong_source_snapshots(self):
        path, spec = self.import_spec()
        for field in ('consistent_shutdown_confirmed', 'matching_artifacts_confirmed'):
            changed = copy.deepcopy(spec); changed[field] = False
            path.write_text(json.dumps(changed))
            with self.subTest(field=field), self.assertRaises(snapshots.SnapshotError):
                snapshots.review_import(self.work, path, self.cloud)
        changed = copy.deepcopy(spec); changed['nodes'].pop()
        path.write_text(json.dumps(changed))
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.review_import(self.work, path, self.cloud)
        path.write_text(json.dumps(spec))
        self.cloud.images[201]['created_from']['id'] = 999
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.review_import(self.work, path, self.cloud)
        self.assertFalse((self.work / snapshots.STORE).exists())

    def test_import_rejects_lost_ips_and_different_installation_identity(self):
        path, _ = self.import_spec()
        self.cloud.ips[10]['ip'] = '192.0.2.99'
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.review_import(self.work, path, self.cloud)
        self.cloud.ips[10]['ip'] = '192.0.2.1'
        self.cloud.ips[10]['auto_delete'] = True
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.review_import(self.work, path, self.cloud)
        self.cloud.ips[10]['auto_delete'] = False
        kube = self.work / 'ignition/auth/kubeconfig'
        kube.write_text(kube.read_text().replace(self.domain, 'other.example.com'))
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.review_import(self.work, path, self.cloud)

    def test_import_template_does_not_overwrite_a_reviewed_plan(self):
        path = self.work / 'snapshot-import.json'
        snapshots.import_template(self.work, path)
        spec = json.loads(path.read_text())
        self.assertFalse(spec['consistent_shutdown_confirmed'])
        self.assertEqual(spec['nodes'][0]['image'], 0)
        with self.assertRaises(FileExistsError):
            snapshots.import_template(self.work, path)

    def test_failed_import_copy_is_not_published_as_ready(self):
        path, _ = self.import_spec()
        with patch.object(snapshots, 'bundle_files', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                snapshots.import_existing(self.work, path, self.cloud)
        record = self.work / snapshots.STORE / 'import-reviewed' / 'manifest.json'
        self.assertEqual(json.loads(record.read_text())['status'], 'failed')
        with self.assertRaises(snapshots.SnapshotError):
            snapshots.read_manifest(self.work, 'import-reviewed')


if __name__ == '__main__':
    unittest.main()
