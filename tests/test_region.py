"""Offline regression coverage for current Hetzner location availability."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RegionTests(unittest.TestCase):
    def run_region(self, types, region='nbg1', failure=None):
        with tempfile.TemporaryDirectory() as directory:
            fixtures = Path(directory)
            locations = [dict(name=name, city=name, country='DE', network_zone='eu-central')
                         for name in ('nbg1', 'fsn1')]
            (fixtures / 'locations-1.json').write_text(json.dumps({'locations': locations}))
            # Split server types across pages to catch accidental first-page-only reads.
            for page, entries in ((1, types[:1]), (2, types[1:])):
                (fixtures / f'server_types-{page}.json').write_text(json.dumps({
                    'server_types': entries,
                    'meta': {'pagination': {'next_page': 2 if page == 1 else None}},
                }))
            if failure == 'malformed':
                (fixtures / 'server_types-1.json').write_text('{"error": {"code": "unknown_error"}}')
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', r'''
source "$REPO_ROOT/functions/lifecycle.sh"
source "$REPO_ROOT/functions/region.sh"
log() { :; }
err() { echo "ERROR: $*" >&2; exit 1; }
curl() {
  local url="${!#}" resource page
  echo "$url" >> "$FIXTURES/requests"
  resource=${url#https://api.hetzner.cloud/v1/}
  resource=${resource%%\?*}
  page=${url##*&page=}
  if [ "$FAILURE" = http ] && [ "$resource" = server_types ]; then
    echo 'curl: (22) The requested URL returned error: 401' >&2
    return 22
  fi
  cat "$FIXTURES/$resource-$page.json"
}
select_region
printf 'RESULT:%s\n%s\n' "$LOC" "$CANDIDATES"
'''], env=dict(os.environ, REPO_ROOT=str(ROOT), FIXTURES=directory,
              FAILURE=failure or '', HCLOUD_TOKEN='test', FLAG_REGION=region,
              ASSUME_YES='1'), text=True, capture_output=True)
            self.assertNotIn('datacenters', (fixtures / 'requests').read_text())
            return result

    @staticmethod
    def server(identifier, price, architecture='x86', available=True, deprecation=None):
        # Deliberately omit the retired top-level "deprecated" field.
        return dict(id=identifier, name=f'type{identifier}', architecture=architecture,
                    cores=4, memory=8, disk=80,
                    locations=[dict(name='nbg1', available=available, deprecation=deprecation),
                               dict(name='fsn1', available=False, deprecation=None)],
                    prices=[dict(location='nbg1', price_hourly={'gross': str(price)})])

    def test_filters_current_location_capacity_architecture_and_deprecation(self):
        result = self.run_region([
            self.server(1, .03), self.server(2, .01),
            self.server(3, .005, architecture='arm'),
            self.server(4, .005, available=False),
            self.server(5, .005, deprecation={'announced': '2026-01-01T00:00:00Z'}),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split('RESULT:')[1],
                         'nbg1\ntype2\t4\t8\t80\t0.01\ntype1\t4\t8\t80\t0.03\n')

    def test_deprecation_in_another_location_does_not_exclude_type(self):
        server = self.server(1, .01)
        server['locations'][1]['deprecation'] = {'announced': '2026-01-01T00:00:00Z'}
        result = self.run_region([server])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_no_capacity_in_selected_location(self):
        result = self.run_region([self.server(1, .01)], region='fsn1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('fsn1 has no usable x86 server types', result.stderr)

    def test_http_failure_keeps_status_and_names_resource(self):
        result = self.run_region([self.server(1, .01)], failure='http')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('401', result.stderr)
        self.assertIn('could not fetch Hetzner server types', result.stderr)

    def test_malformed_response_fails(self):
        result = self.run_region([self.server(1, .01)], failure='malformed')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Invalid Hetzner server_types response', result.stderr)


if __name__ == '__main__':
    unittest.main()
