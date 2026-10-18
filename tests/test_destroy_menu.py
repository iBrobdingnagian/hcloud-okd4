"""Destroy menu tests never call a cloud API or run Terraform."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DestroyMenuTests(unittest.TestCase):
    def run_menu(self, choices):
        with tempfile.TemporaryDirectory() as tmp:
            return subprocess.run(['bash', '-euc', '''
source "$1/functions/destroy-menu.sh"
REPO_ROOT=$1 DOMAIN=example.test DEPLOYMENT_TYPE=openshift SNAPSHOT_BEFORE_DESTROY=0
python3(){ echo "READ_ONLY:$*"; }
choose_destroy_action
printf 'RESULT:%s:%s\\n' "$DESTROY_ACTION" "$SNAPSHOT_BEFORE_DESTROY"
''', '_', str(ROOT)], input=choices, text=True, cwd=tmp, capture_output=True)

    def test_snapshot_before_destroy(self):
        result = self.run_menu('1\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('RESULT:destroy:1', result.stdout)
        self.assertNotIn('READ_ONLY:', result.stdout)

    def test_destroy_without_new_snapshot(self):
        result = self.run_menu('2\n')
        self.assertIn('RESULT:destroy:0', result.stdout)
        self.assertIn('original retained Primary IPs', result.stdout)

    def test_lists_return_to_menu_and_cancel(self):
        result = self.run_menu('3\n4\n0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('cluster_snapshot.py list', result.stdout)
        self.assertIn('cluster_snapshot.py discover', result.stdout)
        self.assertIn('RESULT:cancel:0', result.stdout)

    def test_default_eof_and_invalid_choices_do_not_destroy(self):
        for choices in ('\n', '', 'wrong\n0\n'):
            with self.subTest(choices=choices):
                result = self.run_menu(choices)
                self.assertIn('RESULT:cancel:0', result.stdout)


if __name__ == '__main__':
    unittest.main()
