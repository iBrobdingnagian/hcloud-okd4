"""Offline regressions for workstation access after a snapshot restore."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import cluster_access as access


class AccessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.domain = 'dev.example.com'
        self.path = self.work / 'ignition/auth/kubeconfig'
        self.path.parent.mkdir(parents=True)
        (self.work / 'terraform').mkdir()
        self.state = {'resources': [{
            'type': 'hcloud_load_balancer', 'mode': 'managed', 'instances': [
                {'attributes': {'name': 'lb.' + self.domain, 'ipv4': '192.0.2.10'}}
            ]}]}
        self.config = {
            'apiVersion': 'v1', 'kind': 'Config', 'current-context': 'admin',
            'contexts': [{'name': 'admin', 'context': {'cluster': 'dev', 'user': 'admin'}}],
            'users': [{'name': 'admin', 'user': {'token': 'preserved-test-token'}}],
            'clusters': [
                {'name': 'dev', 'cluster': {
                    'server': 'https://api.' + self.domain + ':6443',
                    'certificate-authority-data': 'preserved-test-ca'}},
                {'name': 'other', 'cluster': {'server': 'https://api.other.example:6443'}},
            ],
        }
        self.save()

    def save(self):
        self.path.write_text(yaml.safe_dump(self.config))
        (self.work / 'terraform/terraform.tfstate').write_text(json.dumps(self.state))

    def test_refresh_preserves_credentials_contexts_trust_and_other_clusters(self):
        with patch('socket.getaddrinfo', side_effect=OSError('NXDOMAIN')):
            self.assertEqual(access.refresh(self.work, self.domain), '192.0.2.10')
        expected = copy.deepcopy(self.config)
        expected['clusters'][0]['cluster'].update(
            server='https://192.0.2.10:6443', **{'tls-server-name': 'api.' + self.domain})
        self.assertEqual(yaml.safe_load(self.path.read_text()), expected)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        before = self.path.read_bytes()
        access.refresh(self.work, self.domain)
        self.assertEqual(self.path.read_bytes(), before)

    def test_second_restore_updates_old_ip_and_validation_rejects_stale_ip(self):
        access.refresh(self.work, self.domain)
        self.config = yaml.safe_load(self.path.read_text())
        self.state['resources'][0]['instances'][0]['attributes']['ipv4'] = '192.0.2.20'
        self.save()
        with self.assertRaises(ValueError):
            access.validate_identity(self.config, self.domain, '192.0.2.20')
        access.refresh(self.work, self.domain)
        config = yaml.safe_load(self.path.read_text())
        access.validate_identity(config, self.domain, '192.0.2.20')
        self.assertEqual(access.selected_cluster(config)['server'], 'https://192.0.2.20:6443')

    def test_wrong_domain_missing_identity_and_insecure_config_never_written(self):
        for changes in (
            {'server': 'https://api.other.example.com:6443'},
            {'server': 'https://192.0.2.10:6443'},
            {'tls-server-name': 'api.other.example.com'},
            {'insecure-skip-tls-verify': True},
        ):
            with self.subTest(changes=changes):
                config = copy.deepcopy(self.config)
                config['clusters'][0]['cluster'].update(changes)
                self.path.write_text(yaml.safe_dump(config))
                before = self.path.read_bytes()
                with self.assertRaises(ValueError):
                    access.refresh(self.work, self.domain)
                self.assertEqual(self.path.read_bytes(), before)

    def test_missing_ambiguous_data_only_or_wrong_domain_lb_never_written(self):
        resource = self.state['resources'][0]
        for resources in (
            [], [resource, resource],
            [dict(resource, mode='data')],
            [{'type': 'hcloud_load_balancer', 'instances': [
                {'attributes': {'name': 'lb.other.example.com', 'ipv4': '192.0.2.10'}}]}],
        ):
            with self.subTest(resources=resources):
                (self.work / 'terraform/terraform.tfstate').write_text(json.dumps({'resources': resources}))
                before = self.path.read_bytes()
                with self.assertRaises(ValueError):
                    access.refresh(self.work, self.domain)
                self.assertEqual(self.path.read_bytes(), before)

    def test_restore_checks_user_config_after_refresh_and_ignores_stale_shell_override(self):
        bindir = self.work / 'bin'
        bindir.mkdir()
        # Only allow ordinary oc invocations. Any private --server override fails.
        oc = bindir / 'oc'
        oc.write_text(f'''#!{sys.executable}
import json, os, sys, yaml
from pathlib import Path
args = sys.argv[1:]
assert not any(a.startswith('--server=') for a in args), args
config = yaml.safe_load(Path(os.environ['KUBECONFIG']).read_text())
cluster = config['clusters'][0]['cluster']
assert cluster['server'] == 'https://192.0.2.10:6443', cluster
assert cluster['tls-server-name'] == 'api.dev.example.com', cluster
with Path('oc-calls').open('a') as stream:
    stream.write(' '.join(args) + '\\n')
if args[:2] == ['config', 'view']:
    print(cluster['server'])
elif '--raw=/readyz' in args:
    print('ok')
elif 'nodes' in args:
    print(json.dumps({{'items': [{{'status': {{'conditions': [{{'type': 'Ready', 'status': 'True'}}]}}}}]}}))
elif 'clusteroperators' in args:
    print(json.dumps({{'items': [{{'status': {{'conditions': [
        {{'type': 'Available', 'status': 'True'}},
        {{'type': 'Degraded', 'status': 'False'}},
        {{'type': 'Progressing', 'status': 'False'}}]}}}}]}}))
else:
    raise SystemExit(1)
''')
        oc.chmod(0o700)
        (self.work / 'logs').mkdir()
        script = '''
set -euo pipefail
source "$REPO_ROOT/functions/lifecycle.sh"
source "$REPO_ROOT/functions/snapshots.sh"
err() { echo "$*" >&2; exit 1; }
log() { echo "$*"; }
docker() { return 0; }
load_env() { return 0; }
progress_step() { return 0; }
tb() { return 0; }
schedule_autodestroy() { AUTODESTROY_NOTE=disabled; }
python3() {
  if [[ "$*" == *cluster_snapshot.py* ]]; then return 0; fi
  command python3 "$@"
}
# Simulate the wrapper installed at deploy startup from the previous state.
oc() { command oc --server=https://192.0.2.99:6443 "$@"; }
DOMAIN=dev.example.com
OPENSHIFT_RELEASE=test
ASSUME_YES=1
FLAG_RESTORE_SNAPSHOT=test-snapshot
TF_VAR_replicas_master=1
TF_VAR_replicas_worker=0
restore_cluster_snapshot --restore-snapshot test-snapshot --yes
assert_cluster_context
'''
        result = subprocess.run(
            ['bash', '-c', script], cwd=self.work,
            env=dict(os.environ, REPO_ROOT=str(ROOT), CLUSTER_ID='',
                     PATH=str(bindir) + os.pathsep + os.environ['PATH']),
            text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.work / 'oc-calls').read_text()
        self.assertIn('get --raw=/readyz', calls)
        self.assertIn('get nodes', calls)
        self.assertIn('get clusteroperators', calls)
        self.assertTrue((self.work / '.phases/ready').exists())
        self.assertEqual(json.loads((self.work / 'logs/restore-snapshot.json').read_text())['status'], 'restored')
        self.assertIn('export KUBECONFIG=', result.stdout)


if __name__ == '__main__':
    unittest.main()
