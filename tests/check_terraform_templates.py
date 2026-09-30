#!/usr/bin/env python3
"""Exercise Terraform's actual template renderer without providers or cloud state."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from validate_ignition import validate

with tempfile.TemporaryDirectory(prefix='okd-ignition-render-') as directory:
    work = Path(directory)
    for version in ('3.0.0', '3.2.0', '3.4.0'):
        for ca in ('', 'data:text/plain;base64,dGVzdA=='):
            variables = dict(hostname='master01.dev.example.com', hostname_b64='bWFzdGVyMDE=',
                             resolvconf_b64='bmFtZXNlcnZlciAxLjEuMS4xCg==',
                             ignition_url='https://api-int.dev.example.com:22623/config/master',
                             ignition_version=version, ignition_cacert=ca)
            expression = 'templatefile(' + json.dumps(str(ROOT / 'terraform/modules/hcloud_coreos/templates/ignition.ign')) + ', ' + json.dumps(variables) + ')'
            # jsonencode produces a single quoted result that can be decoded without HCL parsing.
            result = subprocess.run(['terraform', f'-chdir={work}', 'console'],
                                    input='jsonencode(' + expression + ')\n', capture_output=True, text=True, check=True)
            rendered = json.loads(json.loads(result.stdout))
            path = work / 'node.ign'
            path.write_text(rendered)
            validate(path)
            data = json.loads(rendered)
            assert {entry['path'] for entry in data['storage']['files']} == {'/etc/hostname', '/etc/resolv.conf'}
            assert 'merge' in data['ignition']['config']
            assert ('security' in data['ignition']) == bool(ca)
    print('Six rendered Ignition variants passed.')
