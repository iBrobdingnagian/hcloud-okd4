"""Offline controls tests. No cloud credentials or real lifecycle scripts are used."""
import fcntl
import http.client
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import progress_server as progress
from progress_controls import Controls


class ProcessTests(unittest.TestCase):
    def test_process_detection_without_procfs(self):
        results = [subprocess.CompletedProcess([], 0,
                       '123 1-02:03:04 bash deploy-okd.sh --cluster lab\n'
                       '124 00:05 make wait_completion\n'),
                   subprocess.CompletedProcess([], 0,
                       'p123\nn/tmp/lab\np124\nn/tmp/lab\n')]
        with patch.object(progress, '_BOOT', None), \
                patch.object(progress.subprocess, 'run', side_effect=results), \
                patch.object(progress.time, 'time', return_value=200000):
            procs = progress.all_processes()['/tmp/lab']
        self.assertEqual(procs[0], (123, 106216, 'bash deploy-okd.sh --cluster lab'))
        self.assertEqual(procs[1], (124, 199995, 'make wait_completion'))
        self.assertEqual(progress.running_op(procs), ('deploy', 123, 106216))

    def test_missing_process_tools_does_not_break_status(self):
        with patch.object(progress, '_BOOT', None), \
                patch.object(progress.subprocess, 'run', side_effect=FileNotFoundError):
            self.assertEqual(progress.all_processes(), {})


class PortPlanTests(unittest.TestCase):
    """A progress server from another checkout must never be reused."""

    def plan(self, answers):
        def fetch(port):
            answer = answers.get(port)
            if isinstance(answer, Exception):
                raise answer
            return answer
        return progress.port_plan(8093, repo='/repo/hcloud-okd4', fetch=fetch)

    def test_free_port_starts_our_server(self):
        self.assertEqual(self.plan({8093: ConnectionRefusedError()}), ('start', 8093))

    def test_our_server_is_reused(self):
        self.assertEqual(self.plan({8093: {'repo': '/repo/hcloud-okd4'}}), ('reuse', 8093))

    def test_other_checkout_moves_to_next_free_port(self):
        answers = {8093: {'repo': '/repo/azcloud_ocp'}, 8094: ConnectionRefusedError()}
        self.assertEqual(self.plan(answers), ('start', 8094))

    def test_server_without_identity_is_treated_as_foreign(self):
        answers = {8093: {'cluster': 'legacy'}, 8094: ValueError('not json'), 8095: ConnectionRefusedError()}
        self.assertEqual(self.plan(answers), ('start', 8095))

    def test_our_server_found_on_a_later_port_is_reused(self):
        answers = {8093: {'repo': '/repo/azcloud_ocp'}, 8094: {'repo': '/repo/hcloud-okd4'}}
        self.assertEqual(self.plan(answers), ('reuse', 8094))

    def test_port_held_by_another_http_service_is_skipped(self):
        import urllib.error
        busy = urllib.error.HTTPError('http://x/status.json', 404, 'not found', {}, None)
        answers = {8093: busy, 8094: ConnectionRefusedError()}
        self.assertEqual(self.plan(answers), ('start', 8094))

    def test_listener_that_does_not_answer_is_skipped(self):
        import urllib.error
        answers = {8093: urllib.error.URLError(TimeoutError('timed out')), 8094: ConnectionRefusedError()}
        self.assertEqual(self.plan(answers), ('start', 8094))

    def test_status_reports_the_repository_it_serves(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(progress.status('legacy', Path(tmp), [])['repo'], str(progress.REPO))


class ScaleViewTests(unittest.TestCase):
    """A scale run (deploy-okd.sh on an existing cluster) is shown as a scale."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        (self.work / 'logs').mkdir()

    def marker(self, op, title, age=0):
        path = self.work / 'logs/current-step.json'
        path.write_text(json.dumps({'op': op, 'title': title, 'typical': '2-5 min', 'at': '2026-10-17T00:00:00Z'}))
        stamp = time.time() - age
        os.utime(path, (stamp, stamp))

    def plan(self):
        (self.work / 'logs/scale.json').write_text(json.dumps({
            'direction': 'up', 'from': {'masters': 1, 'workers': 0}, 'to': {'masters': 1, 'workers': 2},
            'adding': ['worker01.lab.example.com', 'worker02.lab.example.com'], 'removing': []}))

    def test_running_scale_is_reported_with_its_own_steps_and_plan(self):
        self.marker('scale', 'Applying infrastructure changes (terraform): 1 -> 1 master(s), 0 -> 2 worker(s)')
        self.plan()
        result = progress.status('legacy', self.work, [(10, time.time() - 60, 'bash deploy-okd.sh')])
        self.assertEqual(result['operation'], 'scale')
        self.assertTrue(result['running'])
        self.assertEqual(result['steps'][result['current']['index']], 'Applying infrastructure changes')
        self.assertEqual(result['scale']['to'], {'masters': 1, 'workers': 2})
        self.assertEqual(result['scale']['adding'], ['worker01.lab.example.com', 'worker02.lab.example.com'])

    def test_install_run_is_still_a_deploy(self):
        self.marker('deploy', 'Waiting for install completion')
        result = progress.status('legacy', self.work, [(10, time.time() - 60, 'bash deploy-okd.sh')])
        self.assertEqual(result['operation'], 'deploy')
        self.assertIsNone(result['scale'])

    def test_finished_scale_stays_visible_as_complete(self):
        started = time.time() - 600
        (self.work / 'logs/last-operation.json').write_text(json.dumps({
            'cluster': 'legacy', 'operation': 'deploy', 'exit_code': 0,
            'started': progress.iso(started), 'finished': progress.iso(time.time())}))
        self.marker('scale', 'Scale complete: 1 master(s), 2 worker(s)', age=30)
        self.plan()
        result = progress.status('legacy', self.work, [])
        self.assertEqual(result['operation'], 'scale')
        self.assertTrue(result['complete'])

    def test_old_scale_marker_does_not_take_over_a_new_deploy(self):
        self.marker('scale', 'Scale complete: 1 master(s), 2 worker(s)', age=3600)
        result = progress.status('legacy', self.work, [(10, time.time() - 60, 'bash deploy-okd.sh')])
        self.assertEqual(result['operation'], 'deploy')

    def test_members_table_from_node_list(self):
        nodes = [{
            'metadata': {'name': 'worker01.lab.example.com', 'creationTimestamp': '2026-10-17T00:01:00Z',
                         'labels': {'node-role.kubernetes.io/worker': ''}},
            'spec': {'unschedulable': True},
            'status': {'conditions': [{'type': 'Ready', 'status': 'True'}],
                       'addresses': [{'type': 'InternalIP', 'address': '10.0.1.21'}],
                       'nodeInfo': {'kubeletVersion': 'v1.33.5'}},
        }, {
            'metadata': {'name': 'master01.lab.example.com', 'creationTimestamp': '2026-10-16T22:20:00Z',
                         'labels': {'node-role.kubernetes.io/master': '', 'node-role.kubernetes.io/control-plane': ''}},
            'spec': {},
            'status': {'conditions': [{'type': 'Ready', 'status': 'False'}], 'addresses': [], 'nodeInfo': {}},
        }]
        members = progress.node_members(nodes)
        self.assertEqual([m['name'] for m in members], ['master01.lab.example.com', 'worker01.lab.example.com'])
        self.assertEqual(members[0]['roles'], ['control-plane', 'master'])
        self.assertFalse(members[0]['ready'])
        self.assertEqual(members[1], {'name': 'worker01.lab.example.com', 'roles': ['worker'], 'ready': True,
                                      'schedulable': False, 'created': '2026-10-17T00:01:00Z',
                                      'ip': '10.0.1.21', 'version': 'v1.33.5'})

    def test_every_scale_step_written_by_the_scripts_is_known_to_the_page(self):
        import re
        titles = re.findall(r'progress_step scale "([^"]+)"', (ROOT / 'functions/cluster-scale.sh').read_text())
        self.assertGreaterEqual(len(titles), 6)
        for title in titles:
            self.assertIsNotNone(progress.step_index('scale', title), title)

    def test_shell_helper_records_the_plan_with_node_names(self):
        script = f'REPO_ROOT={ROOT}; . {ROOT}/functions/progress.sh; progress_scale 3 3 3 1 lab.example.com'
        subprocess.run(['bash', '-c', script], cwd=self.work, check=True)
        plan = json.loads((self.work / 'logs/scale.json').read_text())
        self.assertEqual(plan['direction'], 'down')
        self.assertEqual(plan['removing'], ['worker02.lab.example.com', 'worker03.lab.example.com'])
        self.assertEqual(plan['adding'], [])
        subprocess.run(['bash', '-c', script.replace('3 3 3 1', '1 0 3 2')], cwd=self.work, check=True)
        plan = json.loads((self.work / 'logs/scale.json').read_text())
        self.assertEqual(plan['direction'], 'up')
        self.assertEqual(plan['adding'], ['master02.lab.example.com', 'master03.lab.example.com',
                                          'worker01.lab.example.com', 'worker02.lab.example.com'])


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
