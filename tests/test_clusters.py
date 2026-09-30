"""Offline regression tests for isolation and destructive-operation boundaries."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / f'{name}.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


context = module('cluster_context')
state_check = module('check_state')
ignition = module('validate_ignition')


class ClusterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='okd-test-')
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        (self.repo / 'clusters').mkdir()
        (self.repo / '.secrets').mkdir()
        for name in ('Makefile', 'Dockerfile', '.dockerignore'):
            (self.repo / name).write_text('')
        for name in ('terraform', 'ansible', 'packer', 'grafana'):
            (self.repo / name).mkdir()
        (self.repo / 'terraform' / 'main.tf').write_text('# shared source\n')
        self.config('dev', 10)
        self.config('staging', 20)

    def config(self, name, subnet):
        data = yaml.safe_load((ROOT / 'clusters/dev.yaml.example').read_text())
        data.update(name=name, domain=f'{name}.example.com', credentials_file=f'.secrets/{name}.env',
                    ssh_private_key=f'.secrets/{name}_id_rsa')
        data['network'].update(machine=f'10.{subnet}.0.0/16', nodes=f'10.{subnet}.1.0/24', load_balancer=f'10.{subnet}.2.0/24')
        (self.repo / 'clusters' / f'{name}.yaml').write_text(yaml.safe_dump(data))
        (self.repo / f'.secrets/{name}.env').write_text('HCLOUD_TOKEN=test\nCLOUDFLARE_API_TOKEN=test\n')
        (self.repo / f'.secrets/{name}_id_rsa').write_text('PRIVATE TEST KEY\n')
        (self.repo / f'.secrets/{name}_id_rsa.pub').write_text('ssh-ed25519 dGVzdA== test\n')
        return data

    def bash(self, code, **env):
        return subprocess.run(['bash', '-euo', 'pipefail', '-c', code], cwd=self.repo,
                              env=dict(os.environ, REPO_ROOT=str(ROOT), **env), text=True, capture_output=True)

    def test_separate_workspaces_preserve_state_and_identity(self):
        (self.repo / 'terraform/secret.auto.tfvars.json').write_text('{"dns_domain":"wrong.example.com"}')
        dev, _ = context.prepare(self.repo, 'dev', 'deploy')
        (dev / 'terraform/terraform.tfstate').write_text('DEV STATE')
        (dev / 'ignition/auth').mkdir(parents=True)
        (dev / 'ignition/auth/kubeconfig').write_text('DEV KUBECONFIG')
        (dev / '.phases').mkdir()
        (dev / '.phases/configured').touch()
        previous_install = (dev / 'install-config.yaml').read_bytes()
        staging, _ = context.prepare(self.repo, 'staging', 'deploy')
        context.prepare(self.repo, 'dev', 'deploy', resume=True)
        self.assertEqual((dev / 'terraform/terraform.tfstate').read_text(), 'DEV STATE')
        self.assertEqual((dev / 'ignition/auth/kubeconfig').read_text(), 'DEV KUBECONFIG')
        self.assertEqual((dev / 'install-config.yaml').read_bytes(), previous_install)
        self.assertFalse((staging / 'terraform/terraform.tfstate').exists())
        self.assertFalse((self.repo / '.env').exists())
        self.assertFalse((dev / 'terraform/secret.auto.tfvars.json').exists())
        self.assertEqual((dev / '.env').stat().st_mode & 0o777, 0o600)
        install = yaml.safe_load(previous_install)
        self.assertIn('sshKey', install)
        self.assertIn('clusterNetwork', install['networking'])

    def test_operation_locks_are_per_cluster_and_release(self):
        with context.operation_lock(self.repo, 'dev'):
            with self.assertRaisesRegex(context.ConfigError, 'another operation'):
                with context.operation_lock(self.repo, 'dev'):
                    pass
            with context.operation_lock(self.repo, 'staging'):
                pass
        with context.operation_lock(self.repo, 'dev'):
            pass

    def test_configuration_change_cannot_replace_cluster_identity(self):
        work, _ = context.prepare(self.repo, 'dev', 'deploy')
        original = (work / '.env').read_bytes()
        path = self.repo / 'clusters/dev.yaml'
        data = yaml.safe_load(path.read_text())
        data['domain'] = 'different.example.com'
        path.write_text(yaml.safe_dump(data))
        with self.assertRaisesRegex(context.ConfigError, 'domain changed'):
            context.prepare(self.repo, 'dev', 'destroy')
        self.assertEqual((work / '.env').read_bytes(), original)

    def test_destroy_unknown_cluster_and_resume_without_checkpoint_fail(self):
        for operation, resume in (('destroy', False), ('deploy', True)):
            with self.assertRaises(context.ConfigError):
                context.prepare(self.repo, 'dev', operation, resume)
        self.assertFalse((self.repo / '.work/dev').exists())

    def test_generated_environment_cannot_redirect_cluster(self):
        work, _ = context.prepare(self.repo, 'dev', 'deploy')
        env = context.read_env(work / '.env')
        env['TF_VAR_dns_domain'] = 'foreign.example.com'
        context.write_env(work / '.env', env)
        with self.assertRaisesRegex(context.ConfigError, 'differs from cluster identity'):
            context.prepare(self.repo, 'dev', 'destroy')

    def test_worker_only_scale_does_not_supply_master_override(self):
        child = self.repo / 'deploy-okd.sh'
        child.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$HCLOUD_OKD4_CONTEXT_DIR/received-args"\n')
        with patch.dict(os.environ, {}, clear=False):
            self.assertEqual(context.run(self.repo, 'deploy', ['--cluster', 'dev', '--scale', '--workers', '4', '--yes']), 0)
        args = (self.repo / '.work/dev/received-args').read_text().splitlines()
        self.assertIn('--workers', args)
        self.assertNotIn('--masters', args)
        self.assertNotIn('--profile', args)

    def test_timer_has_cluster_identity_and_clears_inherited_context(self):
        result = self.bash('''
. "$REPO_ROOT/functions/autodestroy.sh"
uname() { echo Linux; }
systemctl() { return 0; }
systemd-run() { printf '%s\\n' "$@" > scheduled-args; }
NO_AUTODESTROY=0 ASSUME_YES=1 DUR=8 FLAG_AUTODESTROY_AT=""
CLUSTER_ID=dev AUTODESTROY_ID=dev-checkout
HCLOUD_OKD4_CONTEXT_DIR="$PWD/.work/dev"
schedule_autodestroy
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.repo / 'scheduled-args').read_text()
        self.assertIn('--unit=hcloud-okd4-autodestroy-dev-checkout', args)
        self.assertIn('--cluster dev', args)
        self.assertIn('-u HCLOUD_OKD4_CONTEXT_DIR', args)

    def test_domain_and_cidr_validation(self):
        for field, value in (('domain', 'staging.example.com'), ('masters', 2)):
            data = self.config('dev', 10)
            data[field] = value
            (self.repo / 'clusters/dev.yaml').write_text(yaml.safe_dump(data))
            with self.assertRaises(context.ConfigError):
                context.load_config(self.repo, 'dev')
        data = self.config('dev', 10)
        data['network']['load_balancer'] = '10.20.2.0/24'
        (self.repo / 'clusters/dev.yaml').write_text(yaml.safe_dump(data))
        with self.assertRaisesRegex(context.ConfigError, 'must be inside'):
            context.load_config(self.repo, 'dev')
        with self.assertRaises(context.ConfigError):
            context.load_config(self.repo, '../dev')

    def test_legacy_domain_cannot_be_reused(self):
        (self.repo / '.env').write_text('TF_VAR_dns_domain=dev.example.com\n')
        with self.assertRaisesRegex(context.ConfigError, 'legacy'):
            context.load_config(self.repo, 'dev')

    def test_credentials_cannot_override_cluster_settings(self):
        (self.repo / '.secrets/dev.env').write_text('TF_VAR_dns_domain=foreign.example.com\n')
        with self.assertRaisesRegex(context.ConfigError, 'credentials only'):
            context.prepare(self.repo, 'dev', 'deploy')

    def test_env_loader_preserves_literal_secrets_without_executing(self):
        (self.repo / '.env').write_text('TOKEN="hello world # literal"\nDANGEROUS=$(touch injected)\n')
        result = self.bash('. "$REPO_ROOT/functions/context.sh"; load_env; printf "%s\\n" "$TOKEN" "$DANGEROUS"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'hello world # literal\n$(touch injected)\n')
        self.assertFalse((self.repo / 'injected').exists())

    def test_preview_needs_no_credentials_and_does_not_render_artifacts(self):
        (self.repo / '.secrets/dev.env').unlink()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            context.preview(self.repo, 'dev')
        self.assertIn('Configuration preview only', output.getvalue())
        self.assertFalse((self.repo / '.work/dev').exists())

    def test_autoscaler_cleanup_cannot_cross_cluster_when_network_missing(self):
        (self.repo / 'servers.json').write_text(json.dumps({'servers': [
            {'id': 1, 'name': 'worker-asc-dev-abc', 'labels': {'hcloud/node-group': 'worker-asc-dev'}, 'private_net': []},
            {'id': 2, 'name': 'worker-asc-staging-def', 'labels': {'hcloud/node-group': 'worker-asc-staging'}, 'private_net': [{'network': 20}]},
        ]}))
        script = '. "$REPO_ROOT/functions/lifecycle.sh"; hcloud_list() { cat servers.json; }; ca_node_ids'
        dev = self.bash(script, CLUSTER_ID='dev', CA_NETID='')
        legacy = self.bash(script, CLUSTER_ID='', CA_NETID='')
        self.assertEqual(dev.returncode, 0, dev.stderr)
        self.assertEqual(dev.stdout, '1 worker-asc-dev-abc\n')
        self.assertEqual(legacy.stdout, '')

    def test_failed_drain_prevents_terraform_and_node_deletion(self):
        (self.repo / '.env').write_text('TF_VAR_replicas_worker=2\n')
        result = self.bash('''
. "$REPO_ROOT/functions/lifecycle.sh"
. "$REPO_ROOT/functions/cluster-scale.sh"
log() { :; }
docker() { return 0; }
oc() {
  printf '%s\\n' "$*" >> oc-calls
  case "$*" in
    'config view '*) echo https://api.dev.example.com:6443 ;;
    'adm drain '*) return 1 ;;
  esac
}
tb() { touch terraform-called; }
CUR_MASTERS=3 NEW_MASTERS=3 CUR_WORKERS=2 NEW_WORKERS=1 DOMAIN=dev.example.com OPENSHIFT_RELEASE=4.16.0
apply_scale
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.repo / 'terraform-called').exists())
        self.assertNotIn('delete node', (self.repo / 'oc-calls').read_text())
        self.assertEqual((self.repo / '.env').read_text(), 'TF_VAR_replicas_worker=2\n')

    def test_http_failure_is_not_an_empty_fleet(self):
        result = self.bash('''
. "$REPO_ROOT/functions/lifecycle.sh"
curl() { echo '{"error":{"message":"unauthorized"}}'; return 22; }
HCLOUD_TOKEN=test DOMAIN=dev.example.com CLUSTER_ID=dev
cluster_servers
''')
        self.assertNotEqual(result.returncode, 0)

    def test_state_ownership_rejects_other_cluster(self):
        path = self.repo / 'state.json'
        state = {'resources': [{'type': 'hcloud_server', 'instances': [{'attributes': {
            'name': 'master01.staging.example.com', 'labels': {'hcloud-okd4/cluster': 'staging'}}}]}]}
        path.write_text(json.dumps(state))
        with self.assertRaisesRegex(ValueError, 'outside'):
            state_check.check(path, 'dev.example.com', 'dev')
        state_check.check(path, 'staging.example.com', 'staging')

    def test_terraform_wrapper_rejects_foreign_state_before_docker(self):
        (self.repo / 'terraform/terraform.tfstate').write_text(json.dumps({'resources': [
            {'type': 'hcloud_server', 'instances': [{'attributes': {'name': 'master01.staging.example.com'}}]}
        ]}))
        result = self.bash('''
. "$REPO_ROOT/functions/helpers.sh"
docker() { touch docker-called; }
TF_VAR_dns_domain=dev.example.com CLUSTER_ID=dev
tb 'make infrastructure'
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.repo / 'docker-called').exists())

    def test_duplicate_ignition_keys_rejected(self):
        path = self.repo / 'test.ign'
        path.write_text('{"ignition":{"version":"3.0.0"},"storage":{},"storage":{}}')
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            ignition.validate(path)

    def test_all_shell_files_parse(self):
        for path in sorted(ROOT.glob('*.sh')) + sorted((ROOT / 'functions').glob('*.sh')):
            result = subprocess.run(['bash', '-n', str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f'{path}: {result.stderr}')

    def test_help_commands_do_not_need_configuration(self):
        for script in ('deploy', 'destroy', 'power'):
            result = subprocess.run(['bash', str(ROOT / f'{script}-okd.sh'), '--cluster', 'example', '--help'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('--cluster', result.stdout)

    def test_interrupted_deploy_resumes_without_replacing_identity(self):
        # Exercise the real entry point, context parent, config resolution, phases,
        # and final readiness checks with external commands replaced by doubles.
        for directory in ('functions', 'scripts'):
            shutil.copytree(ROOT / directory, self.repo / directory, ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copy2(ROOT / 'deploy-okd.sh', self.repo / 'deploy-okd.sh')
        (self.repo / 'functions/preflight.sh').write_text('preflight_checks() { SSH22_BLOCKED=0; }\n')
        (self.repo / 'functions/watchdog.sh').write_text('install_watchdog() { return 0; }\n')
        with (self.repo / 'functions/helpers.sh').open('a') as stream:
            stream.write('\nflush_dns() { :; }\n')
        binary = self.repo / 'bin'
        binary.mkdir()
        for command in ('docker', 'curl', 'oc', 'nc'):
            shutil.copy2(ROOT / 'tests/fake_cloud.py', binary / command)
            (binary / command).chmod(0o755)
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'])
        first = subprocess.run(['bash', str(self.repo / 'deploy-okd.sh'), '--cluster', 'dev', '--yes'],
                               env=dict(env, FAKE_FAIL='bootstrap'), capture_output=True, text=True, timeout=15)
        self.assertNotEqual(first.returncode, 0)
        work = self.repo / '.work/dev'
        self.assertTrue((work / '.phases/ignition').exists(), first.stdout + first.stderr)
        self.assertFalse((work / '.phases/bootstrap-complete').exists())
        identity = (work / 'ignition/auth/kubeconfig').read_bytes()
        second = subprocess.run(['bash', str(self.repo / 'deploy-okd.sh'), '--cluster', 'dev', '--resume', '--yes'],
                                env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual((work / 'ignition/auth/kubeconfig').read_bytes(), identity)
        self.assertTrue((work / '.phases/ready').exists())
        self.assertEqual((work / 'fake-docker.log').read_text().count('make generate_ignition'), 1)
        # A second cluster uses a different work directory and can complete independently.
        third = subprocess.run(['bash', str(self.repo / 'deploy-okd.sh'), '--cluster', 'staging', '--yes'],
                               env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(third.returncode, 0, third.stdout + third.stderr)
        self.assertTrue((self.repo / '.work/staging/.phases/ready').exists())
        self.assertEqual((work / 'ignition/auth/kubeconfig').read_bytes(), identity)


if __name__ == '__main__':
    unittest.main()
