"""etcd wait after master changes: a healthy revision rollout must not be reported as a failure."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def operator(available='True', progressing='False', degraded='False', message=''):
    return {'status': {'conditions': [
        {'type': 'Available', 'status': available, 'message': 'StaticPodsAvailable'},
        {'type': 'Progressing', 'status': progressing, 'message': message},
        {'type': 'Degraded', 'status': degraded, 'message': ''},
    ]}}


def pods(ready):
    return {'items': [{'status': {'phase': 'Running', 'conditions': [{'type': 'Ready', 'status': 'True'}]}}
                      for _ in range(ready)]}


class EtcdWaitTests(unittest.TestCase):
    def run_wait(self, states, want=3, timeout=60):
        """states: one (ready pods, operator) pair per poll; the last one repeats."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            for i, (ready, op) in enumerate(states):
                (tmp / f'pods.{i}').write_text(json.dumps(pods(ready)))
                (tmp / f'co.{i}').write_text(json.dumps(op))
            script = f'''
                set -u
                REPO_ROOT={ROOT}
                . {ROOT}/functions/rescale.sh
                # oc runs inside $(...) subshells: keep the poll counter in a file
                echo 0 > {tmp}/n; last={len(states) - 1}
                oc() {{
                  local n; n=$(cat {tmp}/n)
                  case "$*" in
                    *"get pods"*) cat {tmp}/pods.$n ;;
                    *"clusteroperator etcd"*) cat {tmp}/co.$n; [ "$n" -lt "$last" ] && echo $((n + 1)) > {tmp}/n; true ;;
                  esac
                }}
                sleep() {{ :; }}
                _wait_etcd_healthy {want} {timeout}
            '''
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                                    env=dict(os.environ, PATH=os.environ['PATH']))
            return result.returncode, result.stdout + result.stderr

    def test_settled_cluster_passes_immediately(self):
        code, _ = self.run_wait([(3, operator())])
        self.assertEqual(code, 0)

    def test_healthy_rollout_longer_than_the_limit_still_succeeds(self):
        rolling = operator(progressing='True', message='NodeInstallerProgressing: 1 node is at revision 8; 2 nodes are at revision 10')
        # 12 polls x 10 s = 120 s of rolling, twice the 60 s limit, then settled
        code, output = self.run_wait([(3, rolling)] * 12 + [(3, operator())], timeout=60)
        self.assertEqual(code, 0, output)
        self.assertIn('revision', output)

    def test_missing_members_still_time_out(self):
        code, output = self.run_wait([(2, operator(progressing='True'))], timeout=60)
        self.assertEqual(code, 1)
        self.assertIn('2/3', output)

    def test_degraded_operator_is_not_given_extra_time(self):
        code, _ = self.run_wait([(3, operator(progressing='True', degraded='True'))], timeout=60)
        self.assertEqual(code, 1)

    def test_rollout_is_bounded(self):
        rolling = operator(progressing='True', message='NodeInstallerProgressing: stuck')
        code, output = self.run_wait([(3, rolling)], timeout=60)
        self.assertEqual(code, 1)
        self.assertIn('rolling', output)


if __name__ == '__main__':
    unittest.main()
