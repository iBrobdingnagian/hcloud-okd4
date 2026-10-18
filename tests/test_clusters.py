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
        # Scripts under test must never start a real progress server: it would
        # outlive the test, bound to a port, serving a deleted temp directory.
        quiet = patch.dict(os.environ, {'PROGRESS_SERVER': '0'})
        quiet.start()
        self.addCleanup(quiet.stop)
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

    def test_context_check_explains_missing_installer_credentials(self):
        result = self.bash(f'source "{ROOT}/functions/lifecycle.sh"; DOMAIN=dev.example.com; '
                           'KUBECONFIG="$PWD/missing"; oc(){ echo unexpected-oc >&2; return 99; }; '
                           'assert_cluster_context')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing installer kubeconfig', result.stderr)
        self.assertIn('--cluster openshift', result.stderr)
        self.assertNotIn('unexpected-oc', result.stderr)

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

    def test_fresh_interactive_workspace_prompts_for_region_and_live_types(self):
        child = self.repo / 'deploy-okd.sh'
        child.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$HCLOUD_OKD4_CONTEXT_DIR/received-args"\n')
        with patch.object(context.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='1'):
            self.assertEqual(context.run(self.repo, 'deploy', ['--cluster', 'dev']), 0)
        args = (self.repo / '.work/dev/received-args').read_text().splitlines()
        for flag in ('--region', '--master-type', '--worker-type', '--masters', '--workers', '--profile', '--duration'):
            self.assertNotIn(flag, args)
        self.assertIn('--release', args)

    def saved_snapshot(self, name='dev', snapshot='saved-set', status='ready', domain=None, cluster=None):
        directory = self.repo / '.work' / name / '.cluster-snapshots' / snapshot
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'manifest.json').write_text(json.dumps(dict(version=1, status=status,
            domain=domain or f'{name}.example.com', cluster=name if cluster is None else cluster,
            nodes=[{'name': 'master01'}])))
        return directory

    def test_restore_picker_routes_only_completed_snapshots_for_selected_cluster(self):
        self.saved_snapshot(snapshot='a-good')
        self.saved_snapshot(snapshot='b-incomplete', status='incomplete')
        self.saved_snapshot(snapshot='c-foreign-domain', domain='other.example.com')
        self.saved_snapshot(snapshot='d-foreign-cluster', cluster='other')
        self.saved_snapshot(name='staging', snapshot='another-workspace')
        output = io.StringIO()
        with patch.object(context.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='1'), contextlib.redirect_stdout(output):
            args = context.choose_deploy_operation(self.repo, 'dev', ['--restore', '--no-autodestroy'])
        self.assertEqual(args, ['--restore-snapshot', 'a-good', '--no-autodestroy'])
        for excluded in ('b-incomplete', 'c-foreign-domain', 'd-foreign-cluster', 'another-workspace'):
            self.assertNotIn(excluded, output.getvalue())

    def test_startup_restore_option_removes_routing_flag_and_uses_saved_configuration(self):
        self.saved_snapshot()
        with patch.object(context.sys.stdin, 'isatty', return_value=True), patch('builtins.input', side_effect=['2', '1']):
            args = context.choose_deploy_operation(self.repo, 'dev', ['--distribution', 'okd'])
        self.assertEqual(args, ['--restore-snapshot', 'saved-set'])

    def test_restore_selection_cancel_never_prepares_or_runs_deployment(self):
        self.saved_snapshot()
        with patch.object(context.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='0'), patch.object(context, 'prepare') as prepare, patch.object(context.subprocess, 'Popen') as spawn:
            self.assertEqual(context.run(self.repo, 'deploy', ['--cluster', 'dev', '--restore']), 0)
        prepare.assert_not_called()
        spawn.assert_not_called()

    def test_startup_cancel_never_prepares_or_runs_deployment(self):
        with patch.object(context.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='0'), patch.object(context, 'prepare') as prepare, patch.object(context.subprocess, 'Popen') as spawn:
            self.assertEqual(context.run(self.repo, 'deploy', ['--cluster', 'dev']), 0)
        prepare.assert_not_called()
        spawn.assert_not_called()

    def test_restore_picker_requires_interactive_selection_not_yes_defaults(self):
        with patch.object(context.sys.stdin, 'isatty', return_value=False):
            with self.assertRaisesRegex(context.ConfigError, 'interactive terminal'):
                context.choose_deploy_operation(self.repo, 'dev', ['--restore'])
        with patch.object(context.sys.stdin, 'isatty', return_value=True):
            with self.assertRaisesRegex(context.ConfigError, 'interactive terminal'):
                context.choose_deploy_operation(self.repo, 'dev', ['--restore', '--yes'])

    def test_restore_picker_rejects_missing_or_invalid_selection_without_fallback(self):
        with patch.object(context.sys.stdin, 'isatty', return_value=True):
            with self.assertRaisesRegex(context.ConfigError, 'No completed local snapshots'):
                context.choose_deploy_operation(self.repo, 'dev', ['--restore'])
        self.saved_snapshot()
        for selection in ('', '2', '-1', 'deploy'):
            with patch.object(context.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value=selection):
                with self.assertRaisesRegex(context.ConfigError, 'invalid snapshot selection'):
                    context.choose_deploy_operation(self.repo, 'dev', ['--restore'])

    def test_restore_picker_rejects_configuration_overrides_and_wrong_distribution(self):
        with patch.object(context.sys.stdin, 'isatty', return_value=True):
            for args in (['--restore', '--workers', '5'], ['--restore', '--distribution', 'openshift']):
                with self.assertRaises(context.ConfigError):
                    context.choose_deploy_operation(self.repo, 'dev', args)

    def test_explicit_restore_and_other_lifecycle_commands_do_not_open_menu(self):
        with patch.object(context.sys.stdin, 'isatty', return_value=True), patch('builtins.input', side_effect=AssertionError('unexpected menu')):
            for args in (['--restore-snapshot', 'saved-set'], ['--snapshot-list'], ['--resume'], ['--scale'], ['--yes']):
                self.assertEqual(context.choose_deploy_operation(self.repo, 'dev', args), args)

    def test_restore_picker_child_receives_restore_not_install_arguments(self):
        self.saved_snapshot()
        child = self.repo / 'deploy-okd.sh'
        child.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$HCLOUD_OKD4_CONTEXT_DIR/received-args"\n')
        with patch.object(context.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='1'):
            self.assertEqual(context.run(self.repo, 'deploy', ['--cluster', 'dev', '--restore']), 0)
        args = (self.repo / '.work/dev/received-args').read_text().splitlines()
        self.assertEqual(args[:2], ['--restore-snapshot', 'saved-set'])
        for flag in ('--release', '--region', '--profile', '--masters', '--workers'):
            self.assertNotIn(flag, args)

    def test_openshift_uses_same_automatic_profile_and_price_selection(self):
        result = self.bash("""
source "$REPO_ROOT/functions/profiles.sh"
source "$REPO_ROOT/functions/server-types.sh"
log(){ :; }
err(){ echo "$*" >&2; exit 1; }
DEPLOYMENT_TYPE=openshift FLAG_PROFILE=2 ASSUME_YES=0
FLAG_MASTERS= FLAG_WORKERS= FLAG_MASTER_TYPE= FLAG_WORKER_TYPE=
select_profile
LOC=nbg1
CANDIDATES=$'cpx42\\t8\\t16\\t320\\t0.11\\nccx33\\t8\\t32\\t240\\t0.20'
pick_type master "$MIN_C_MASTER" "$MIN_R_MASTER" "" "$TYPE_PREFIX" "$TYPE_STRATEGY"
test "$PROFILE:$MASTERS:$WORKERS:$PICKED_TYPE:$PICKED_PRICE" = '2:3:3:cpx42:0.11'
""")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_interactive_incomplete_workspace_offers_resume(self):
        work, _ = context.prepare(self.repo, 'dev', 'deploy')
        (work / '.phases').mkdir()
        (work / '.phases/configured').touch()
        original = (work / '.env').read_bytes()
        with patch.object(context.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value=''):
            self.assertEqual(context.offer_resume(work, ['--no-autodestroy']), ['--no-autodestroy', '--resume'])
        self.assertEqual((work / '.env').read_bytes(), original)
        with patch.object(context.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='n'):
            with self.assertRaisesRegex(context.ConfigError, 'cancelled'):
                context.offer_resume(work, [])

    def test_missing_ignition_cannot_resume_from_startup_menu(self):
        work, _ = context.prepare(self.repo, 'dev', 'deploy')
        (work / '.phases').mkdir()
        (work / '.phases/configured').touch()
        (work / '.phases/ignition').touch()
        with self.assertRaisesRegex(context.ConfigError, 'artifacts are missing'):
            context.offer_resume(work, [])

    def test_selected_region_persists_for_resume_and_destroy(self):
        work, _ = context.prepare(self.repo, 'dev', 'deploy')
        values = context.read_env(work / '.env')
        values.update(TF_VAR_location='hel1', TF_VAR_network_zone='eu-central')
        context.write_env(work / '.env', values)
        config = self.repo / 'clusters/dev.yaml'
        context.save_region_selection(config, work)
        self.assertEqual(context.load_config(self.repo, 'dev')['region'], 'hel1')
        context.prepare(self.repo, 'dev', 'destroy')
        (work / '.phases').mkdir()
        (work / '.phases/configured').touch()
        context.prepare(self.repo, 'dev', 'deploy', resume=True)
        with self.assertRaises(context.ConfigError):
            context.save_region_selection(config, work)

    def test_host_api_uses_owned_lb_with_tls_hostname_and_preserves_config_views(self):
        state = {'resources': [{'type': 'hcloud_load_balancer', 'mode': 'managed', 'instances': [
            {'attributes': {'name': 'lb.dev.example.com', 'ipv4': '192.0.2.10'}}]}]}
        (self.repo / 'terraform/terraform.tfstate').write_text(json.dumps(state))
        bindir = self.repo / 'bin';bindir.mkdir()
        oc = bindir / 'oc';oc.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$PWD/oc-args"\n');oc.chmod(0o700)
        result = self.bash('source "$REPO_ROOT/functions/lifecycle.sh"; '
                           'DOMAIN=dev.example.com; PATH="$PWD/bin:$PATH"; '
                           'configure_host_api; oc get nodes; oc config view --minify')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.repo / 'oc-args').read_text().splitlines()
        self.assertIn('--server=https://192.0.2.10:6443', calls[0])
        self.assertIn('--tls-server-name=api.dev.example.com', calls[0])
        self.assertNotIn('insecure', calls[0])
        self.assertEqual(calls[1], 'config view --minify')

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
date() { if [ "$1" = -d ]; then echo test-deadline; else command date "$@"; fi; }
systemctl() { return 0; }
systemd-run() { printf '%s\\n' "$@" > scheduled-args; }
NO_AUTODESTROY=0 ASSUME_YES=1 DUR=8 FLAG_AUTODESTROY_AT=""
CLUSTER_ID=dev AUTODESTROY_ID=dev-checkout
HCLOUD_OKD4_CONTEXT_DIR="$PWD/.work/dev"
touch .snapshot-before-destroy
schedule_autodestroy
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.repo / 'scheduled-args').read_text()
        self.assertIn('--unit=hcloud-okd4-autodestroy-dev-checkout', args)
        self.assertIn('--cluster dev', args)
        self.assertIn('-u HCLOUD_OKD4_CONTEXT_DIR', args)
        self.assertIn('--snapshot-before-destroy', args)

    def test_snapshot_commands_do_not_receive_fresh_deployment_defaults(self):
        child = self.repo / 'deploy-okd.sh'
        child.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$HCLOUD_OKD4_CONTEXT_DIR/received-args"\n')
        for request in (['--snapshot-list'], ['--restore-snapshot', 'saved-set', '--yes'],
                        ['--snapshot-cloud-list'], ['--snapshot-import-template', 'snapshot-import.json'],
                        ['--snapshot-import-plan', 'snapshot-import.json'], ['--snapshot-import', 'snapshot-import.json']):
            with self.subTest(request=request):
                self.assertEqual(context.run(self.repo, 'deploy', ['--cluster', 'dev', *request]), 0)
                args = (self.repo / '.work/dev/received-args').read_text().splitlines()
                self.assertNotIn('--profile', args)
                self.assertNotIn('--masters', args)
                self.assertNotIn('--release', args)

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

    def test_destroy_continues_autoscaler_cleanup_when_api_dns_is_unavailable(self):
        result = self.bash('''
. "$REPO_ROOT/functions/lifecycle.sh"
oc() {
  printf '%s\\n' "$*" >> oc-calls
  echo 'Unable to connect to the server: dial tcp: lookup api.dev.example.com: no such host' >&2
  return 1
}
stop_cluster_autoscaler_before_destroy
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('continuing with Hetzner autoscaler-node cleanup', result.stderr)
        self.assertEqual((self.repo / 'oc-calls').read_text(),
                         '-n cluster-autoscaler get deployment cluster-autoscaler --ignore-not-found -o name\n')

    def test_destroy_stops_autoscaler_on_non_transport_api_errors(self):
        result = self.bash('''
. "$REPO_ROOT/functions/lifecycle.sh"
oc() { echo 'Error from server (Forbidden): deployments is forbidden' >&2; return 1; }
stop_cluster_autoscaler_before_destroy
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Forbidden', result.stderr)

    def test_failed_drain_prevents_terraform_and_node_deletion(self):
        (self.repo / 'ignition/auth').mkdir(parents=True)
        (self.repo / 'ignition/auth/kubeconfig').write_text('# fixture: oc is mocked below\n')
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
        for command in ('docker', 'curl', 'oc', 'nc', 'sleep'):
            shutil.copy2(ROOT / 'tests/fake_cloud.py', binary / command)
            (binary / command).chmod(0o755)
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'])
        first = subprocess.run(['bash', str(self.repo / 'deploy-okd.sh'), '--cluster', 'dev', '--yes'],
                               env=dict(env, FAKE_FAIL='bootstrap', FAKE_MCS_UNAVAILABLE='1'),
                               capture_output=True, text=True, timeout=15)
        self.assertNotEqual(first.returncode, 0)
        work = self.repo / '.work/dev'
        self.assertTrue((work / '.phases/ignition').exists(), first.stdout + first.stderr)
        # Slow bootstrap/image pulls must not trigger a destructive hard reset.
        self.assertFalse((work / 'fake-reset-requested').exists(), first.stdout + first.stderr)
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
