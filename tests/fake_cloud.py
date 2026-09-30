#!/usr/bin/env python3
"""Command doubles for deployment integration tests. No network or real containers."""
import json
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
work = Path.cwd()
env = {}
if (work / '.env').exists():
    env = dict(line.split('=', 1) for line in (work / '.env').read_text().splitlines() if '=' in line and not line.startswith('#'))
domain = env.get('TF_VAR_dns_domain', 'dev.example.com')
cluster = env.get('TF_VAR_cluster_id', 'dev')

if command == 'docker':
    if args[0] != 'run':
        sys.exit(0)
    script = args[-1]
    with (work / 'fake-docker.log').open('a') as log:
        log.write(script + '\n')
    if 'make wait_bootstrap' in script and os.environ.get('FAKE_FAIL') == 'bootstrap':
        sys.exit(1)
    if 'coreos print-stream-json' in script:
        print('test-coreos-release')
    elif 'make generate_manifests' in script:
        (work / 'config').mkdir(exist_ok=True)
        (work / 'config/.openshift_install_state.json').write_text('{}')
    elif 'make generate_ignition' in script:
        (work / 'ignition/auth').mkdir(parents=True, exist_ok=True)
        for name in ('master', 'worker', 'bootstrap'):
            (work / f'ignition/{name}.ign').write_text(json.dumps({'ignition': {'version': '3.0.0'}}))
        (work / 'ignition/auth/kubeconfig').write_text('PERSISTENT TEST IDENTITY')
        (work / 'ignition/auth/kubeadmin-password').write_text('TEST PASSWORD')
    elif 'make infrastructure' in script:
        servers = []
        for role in ('master', 'worker', 'bootstrap'):
            count = (1 if 'BOOTSTRAP=true' in script else 0) if role == 'bootstrap' else int(env['TF_VAR_replicas_' + role])
            for index in range(count):
                servers.append({'id': len(servers) + 1, 'name': f'{role}{index + 1:02d}.{domain}',
                                'labels': {'hcloud-okd4/cluster': cluster},
                                'public_net': {'ipv4': {'ip': '192.0.2.1'}}})
        (work / 'fake-servers.json').write_text(json.dumps({'servers': servers}))
elif command == 'curl':
    url = args[-1]
    if '/locations' in url:
        print(json.dumps({'locations': [{'id': 1, 'name': 'nbg1', 'city': 'Nuremberg', 'country': 'DE', 'network_zone': 'eu-central'}]}))
    elif '/datacenters' in url:
        print(json.dumps({'datacenters': [{'location': {'name': 'nbg1'}, 'server_types': {'available': [1, 2]}}]}))
    elif '/server_types' in url:
        print(json.dumps({'server_types': [{'id': i, 'name': name, 'architecture': 'x86', 'deprecated': False,
            'cores': 8, 'memory': 32, 'disk': 100, 'prices': [{'location': 'nbg1', 'price_hourly': {'gross': '0.1'}}]}
            for i, name in ((1, 'cpx41'), (2, 'cpx21'))]}))
    elif '/images?' in url:
        print('{"images":[{"id":1}]}')
    elif '/servers' in url:
        servers = json.loads((work / 'fake-servers.json').read_text()) if (work / 'fake-servers.json').exists() else {'servers': []}
        if '?name=bootstrap' in url:
            servers['servers'] = [s for s in servers['servers'] if s['name'].startswith('bootstrap')]
        print(json.dumps(servers))
    elif url.endswith('/healthz'):
        pass
    else:
        raise SystemExit('unexpected fake curl request: ' + url)
elif command == 'oc':
    if args[:2] == ['get', 'nodes']:
        for role in ('master', 'worker'):
            for index in range(int(env['TF_VAR_replicas_' + role])):
                print(f'{role}{index + 1:02d}.{domain} Ready {role} 1d v1.29.0')
    elif args[:2] == ['get', 'clusteroperators']:
        print(json.dumps({'items': [{'status': {'conditions': [
            {'type': 'Available', 'status': 'True'}, {'type': 'Degraded', 'status': 'False'},
            {'type': 'Progressing', 'status': 'False'}]}}]}))
    elif args[:2] == ['config', 'view']:
        print(f'https://api.{domain}:6443')
    elif args[:2] == ['get', 'csr'] or args[:1] == ['get'] and '--raw=/readyz' in args:
        pass
    else:
        raise SystemExit('unexpected fake oc request: ' + ' '.join(args))
elif command == 'nc':
    pass
else:
    raise SystemExit('unexpected fake command: ' + command)
