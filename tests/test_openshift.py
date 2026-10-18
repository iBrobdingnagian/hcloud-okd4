import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import openshift_config
import openshift_versions
import cluster_context


class OpenShiftTests(unittest.TestCase):
    def shell(self, script, cwd):
        return subprocess.run(['bash', '-c', 'set -eu; err(){ echo "$*" >&2; exit 1; }; log(){ :; }; '
                               + f'source "{ROOT}/functions/distribution.sh"; '
                               + 'FLAG_DISTRIBUTION=""; FLAG_PULL_SECRET=""; FLAG_RELEASE=""; '
                               + script], cwd=cwd, capture_output=True, text=True)

    def test_default_okd_needs_no_pull_secret(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.shell('configure_distribution; test "$DEPLOYMENT_TYPE" = okd', tmp).returncode, 0)

    def test_existing_cluster_cannot_change_distribution(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp)/'.phases').mkdir();(Path(tmp)/'.phases/configured').touch()
            result = self.shell('FLAG_DISTRIBUTION=openshift; FLAG_RELEASE=4.18.1; configure_distribution', tmp)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('cannot change distribution', result.stderr)

    def test_openshift_requires_exact_version_before_secret_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.shell('FLAG_DISTRIBUTION=openshift; FLAG_RELEASE=4.18; configure_distribution', tmp)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('4.MINOR.PATCH', result.stderr)

    def test_dummy_pull_secret_rejected(self):
        with self.assertRaises(ValueError):
            openshift_config.validate_pull_secret('{"auths":{"none":{"auth":"none"}}}')

    def test_secret_import_and_private_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            config=Path(tmp)/'install-config.yaml';config.write_text('apiVersion: v1\npullSecret: dummy\n')
            secret=Path(tmp)/'secret.json';secret.write_text(json.dumps({'auths':{'quay.io':{'auth':'test-only'}}}))
            result=subprocess.run([sys.executable,str(ROOT/'scripts/openshift_config.py'),str(config),str(secret)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(config.stat().st_mode & 0o777,0o600)
            self.assertNotIn('test-only',result.stdout+result.stderr)
            self.assertEqual(openshift_config.yaml.safe_load(config.read_text())['apiVersion'],'v1')

    def test_named_config_distribution_and_secret_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo=Path(tmp);(repo/'clusters').mkdir()
            config=openshift_config.yaml.safe_load((ROOT/'clusters/dev.yaml.example').read_text())
            path=repo/'clusters/dev.yaml'
            path.write_text(openshift_config.yaml.safe_dump(config))
            self.assertEqual(cluster_context.load_config(repo,'dev')['distribution'],'okd')
            config.update(distribution='openshift',release='4.18.1',pull_secret_file='.secrets/pull-secret.json')
            path.write_text(openshift_config.yaml.safe_dump(config))
            self.assertEqual(cluster_context.config_env(cluster_context.load_config(repo,'dev'))['DEPLOYMENT_TYPE'],'openshift')
            del config['pull_secret_file']
            path.write_text(openshift_config.yaml.safe_dump(config))
            with self.assertRaises(cluster_context.ConfigError):
                cluster_context.load_config(repo,'dev')

    def test_destroy_rejects_wrong_distribution_before_cloud_calls(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp)/'.env').write_text('DEPLOYMENT_TYPE=openshift\n')
            result=subprocess.run(['bash',str(ROOT/'destroy-okd.sh'),'--distribution','okd'],
                                  env=dict(os.environ,HCLOUD_OKD4_CONTEXT_DIR=tmp,PROGRESS_SERVER='0'),
                                  capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('does not match the recorded cluster',result.stderr)

    def test_legacy_env_defaults_and_cli_precedence(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp)/'install-config.yaml').write_text('pullSecret: dummy\n')
            secret=Path(tmp)/'pull-secret.json'
            secret.write_text(json.dumps({'auths':{'quay.io':{'auth':'test-only'}}}))
            defaults=f'REPO_ROOT="{ROOT}"; FLAG_DISTRIBUTION=openshift; RH_OPENSHIFT_RELEASE=4.18.1; RH_PULL_SECRET_FILE="{secret}"; '
            result=self.shell(defaults+'configure_distribution; test "$FLAG_RELEASE" = 4.18.1',tmp)
            self.assertEqual(result.returncode,0,result.stderr)
            result=self.shell(defaults+'FLAG_RELEASE=4.18.2; configure_distribution; test "$FLAG_RELEASE" = 4.18.2',tmp)
            self.assertEqual(result.returncode,0,result.stderr)

    def test_release_choices_sort_numerically_and_exclude_prereleases(self):
        html='<a href="4.9.9/">old</a><a href="4.20.1/">a</a><a href="4.20.10/">b</a><a href="4.21.0-rc.1/">rc</a>'
        self.assertEqual(openshift_versions.release_choices(html),['4.20.10','4.9.9'])

    def test_interactive_release_menu_pins_choice(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'scripts').mkdir()
            (root/'scripts/openshift_versions.py').write_text('print("4.20.10\\n4.19.12")')
            result=self.shell(f'REPO_ROOT="{root}"; DEPLOYMENT_TYPE=openshift; ASSUME_YES=0; source "{ROOT}/functions/release.sh"; select_release <<< 2; test "$OPENSHIFT_RELEASE" = 4.19.12',tmp)
            self.assertEqual(result.returncode,0,result.stderr)

    def test_start_menu_routes_openshift_before_workspace_preparation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'clusters').mkdir()
            (root/'.env').write_text('DEPLOYMENT_TYPE=okd\n')
            (root/'clusters/openshift.yaml').write_text('distribution: openshift\n')
            with patch.object(sys.stdin,'isatty',return_value=True), patch('builtins.input',return_value='2'):
                args=cluster_context.route_distribution(root,'deploy',[])
            self.assertEqual(args,['--distribution','openshift','--cluster','openshift'])
            self.assertFalse((root/'.work').exists())
            self.assertEqual((root/'.env').read_text(),'DEPLOYMENT_TYPE=okd\n')

    def test_start_menu_routes_okd_to_legacy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'.env').write_text('DEPLOYMENT_TYPE=okd\n')
            with patch.object(sys.stdin,'isatty',return_value=True), patch('builtins.input',return_value='1'):
                self.assertEqual(cluster_context.route_distribution(root,'deploy',[]),['--distribution','okd'])

    def test_explicit_workspace_and_resume_never_prompt(self):
        with patch.object(sys.stdin,'isatty',return_value=True), patch('builtins.input',side_effect=AssertionError('unexpected menu')):
            for args in (['--cluster','openshift'],['--resume'],['--yes'],['--snapshot-list']):
                self.assertEqual(cluster_context.route_distribution(ROOT,'deploy',args),args)

    def test_missing_openshift_config_does_not_fall_back_to_okd(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(sys.stdin,'isatty',return_value=True), patch('builtins.input',return_value='2'):
                with self.assertRaises(cluster_context.ConfigError):
                    cluster_context.route_distribution(Path(tmp),'deploy',[])

    def test_resume_does_not_turn_recorded_release_into_cli_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp)/'.phases').mkdir()
            (Path(tmp)/'.phases/configured').touch()
            result=self.shell('DEPLOYMENT_TYPE=openshift; OPENSHIFT_RELEASE=4.18.1; FLAG_RESUME=1; '
                              'configure_distribution; test -z "$FLAG_RELEASE"; '
                              'test "$OPENSHIFT_RELEASE" = 4.18.1',tmp)
            self.assertEqual(result.returncode,0,result.stderr)
            result=self.shell('DEPLOYMENT_TYPE=openshift; OPENSHIFT_RELEASE=4.18.1; FLAG_RELEASE=4.18.2; '
                              'configure_distribution; test "$FLAG_RELEASE" = 4.18.2',tmp)
            self.assertEqual(result.returncode,0,result.stderr)

    def test_openshift_fetch_uses_redhat_and_checksums(self):
        result=subprocess.run(['make','-n','fetch','DEPLOYMENT_TYPE=openshift','OPENSHIFT_RELEASE=4.18.1'],cwd=ROOT,capture_output=True,text=True,check=True)
        self.assertIn('mirror.openshift.com',result.stdout)
        self.assertNotIn('github.com/okd-project',result.stdout)
        self.assertIn('shasum -a 256 -c',result.stdout)
        self.assertIn('versioned=',result.stdout)


if __name__ == '__main__':
    unittest.main()
