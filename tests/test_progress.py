"""Offline controls tests. No cloud credentials or real lifecycle scripts are used."""
import fcntl
import http.client
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import progress_server as progress
from progress_controls import Controls


class ControlsFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        (self.repo / 'clusters').mkdir()
        (self.repo / 'clusters/dev.yaml').touch()
        (self.repo / 'clusters/sample.yaml.example').touch()
        self.controls = Controls(self.repo)

    def request(self, operation='deploy', cluster='legacy', **options):
        return dict(operation=operation, cluster=cluster, options=options,
                    confirm=f'{operation} {cluster}')


class ControlsTests(ControlsFixture):
    def test_commands_use_existing_scripts_and_pinned_configuration(self):
        self.assertEqual(self.controls.clusters(), ['legacy', 'dev'])
        self.assertEqual(self.controls.command(self.request('resume', 'dev')),
                         ['bash', str(self.repo / 'deploy-okd.sh'), '--yes', '--cluster', 'dev', '--resume'])
        self.assertEqual(self.controls.command(self.request('destroy', 'dev')),
                         ['bash', str(self.repo / 'destroy-okd.sh'), '--yes', '--cluster', 'dev'])
        args = self.controls.command(self.request(profile='3', **{'lab-topology': '1x0', 'lab-tier': 'low', 'duration': '90m', 'no-autodestroy': True}))
        self.assertIn('--no-autodestroy', args)
        self.assertIn('1x0', args)

    def test_rejects_unconfirmed_unknown_or_invalid_operations(self):
        invalid = [None, [], self.request('destroy', '../dev'), self.request('shell'),
                   self.request('deploy', 'missing'), self.request('deploy', 'dev', profile='2'),
                   self.request('resume', profile='2'), self.request(profile='2', masters='5'),
                   self.request(profile='3', **{'lab-tier': 'unknown'}),
                   self.request(region='nbg1; touch /tmp/unsafe'), self.request(extra='--help'),
                   self.request(**{'no-autodestroy': 'true'}),
                   dict(self.request('destroy'), confirm='yes')]
        for request in invalid:
            with self.subTest(request=request), self.assertRaises(ValueError):
                self.controls.command(request)

    def test_token_is_private_and_rotates(self):
        self.controls.save_token()
        path = self.repo / 'logs/progress-control-token'
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.read_text().strip(), self.controls.token)
        second = Controls(self.repo)
        second.save_token()
        self.assertNotEqual(second.token, self.controls.token)
        self.assertEqual(path.read_text().strip(), second.token)

    def test_launch_is_detached_and_clears_inherited_context(self):
        # A harmless script records its arguments/environment and fails early.
        (self.repo / 'deploy-okd.sh').write_text(
            'printf "args:%s\\n" "$*"\n'
            'printf "context:%s|%s|%s|%s\\n" "${HCLOUD_OKD4_CONTEXT_DIR-unset}" '
            '"${CLUSTER_ID-unset}" "${TF_VAR_dns_domain-unset}" "$PROGRESS_SERVER"\n'
            'echo "preflight failed"\nexit 7\n')
        with patch.dict(os.environ, {'HCLOUD_OKD4_CONTEXT_DIR': '/wrong/workspace',
                                     'CLUSTER_ID': 'wrong', 'TF_VAR_dns_domain': 'wrong.example.com'}):
            result = self.controls.launch(self.request('deploy', 'dev'))
        self.controls.jobs['dev']['process'].wait(timeout=5)
        self.assertEqual(result['status_url'], '/?cluster=dev')
        snapshot = self.controls.snapshot()['jobs']['dev']
        self.assertFalse(snapshot['running'])
        self.assertEqual(snapshot['exit_code'], 7)
        self.assertIn('args:--yes --cluster dev', snapshot['tail'])
        self.assertIn('context:unset|unset|unset|0', snapshot['tail'])
        self.assertIn('preflight failed', snapshot['tail'])
        self.assertEqual((self.repo / 'logs/web-dev.log').stat().st_mode & 0o777, 0o600)

    def test_rejects_overlapping_browser_operation(self):
        with patch('progress_controls.subprocess.Popen') as popen:
            popen.return_value.poll.return_value = None
            self.controls.launch(self.request())
            with self.assertRaises(BlockingIOError):
                self.controls.launch(self.request('destroy'))
            self.assertEqual(popen.call_count, 1)

    def test_rejects_cli_lock_before_spawning(self):
        lock = self.repo / '.work/locks/legacy.lock'
        lock.parent.mkdir(parents=True)
        with lock.open('w') as stream, patch('progress_controls.subprocess.Popen') as popen:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.controls.launch(self.request('destroy'))
            popen.assert_not_called()

    def test_missing_script_is_reported_as_failed_job(self):
        self.controls.launch(self.request('destroy'))
        self.controls.jobs['legacy']['process'].wait(timeout=5)
        self.assertNotEqual(self.controls.snapshot()['jobs']['legacy']['exit_code'], 0)


class HTTPTests(ControlsFixture):
    def setUp(self):
        super().setUp()
        self.server = progress.ThreadingHTTPServer(('127.0.0.1', 0), progress.Handler)
        self.server.controls = self.controls
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def http(self, method, path, body=None, auth=True, **headers):
        if auth:
            headers['Authorization'] = 'Bearer ' + self.controls.token
        if body is not None:
            headers['Content-Type'] = 'application/json'
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def test_public_pages_and_workspace_files(self):
        for route in ('/', '/manage'):
            status, body = self.http('GET', route, auth=False)
            self.assertEqual(status, 200)
            self.assertIn(b'<!doctype html>', body)
            self.assertNotIn(self.controls.token.encode(), body)
        for route in ('/.env', '/logs/progress-control-token', '/logs/web-legacy.log', '/../.env'):
            self.assertEqual(self.http('GET', route)[0], 404)

    def test_unauthorized_requests_cannot_launch_or_read_output(self):
        with patch.object(self.controls, 'launch') as launch:
            self.assertEqual(self.http('GET', '/control.json', auth=False)[0], 403)
            self.assertEqual(self.http('POST', '/operations', json.dumps(self.request()), auth=False)[0], 403)
            self.assertEqual(self.http('POST', '/operations', json.dumps(self.request()), Origin='https://other.example')[0], 403)
            launch.assert_not_called()

    def test_authenticated_launch_and_invalid_payloads(self):
        payload = self.request('destroy', 'dev')
        with patch.object(self.controls, 'launch', return_value={'status_url': '/?cluster=dev'}) as launch:
            code, _ = self.http('POST', '/operations', json.dumps(payload))
            self.assertEqual(code, 202)
            launch.assert_called_once_with(payload)
        for body in ('not json', 'null', '[]', '{}', 'x' * 8193):
            self.assertEqual(self.http('POST', '/operations', body)[0], 400)
        self.assertEqual(self.http('GET', '/operations')[0], 404)

    def test_busy_and_spawn_failure_are_reported(self):
        for error, expected in ((BlockingIOError('busy'), 409), (OSError('unavailable'), 500)):
            with patch.object(self.controls, 'launch', side_effect=error):
                self.assertEqual(self.http('POST', '/operations', json.dumps(self.request()))[0], expected)


if __name__ == '__main__':
    unittest.main()
