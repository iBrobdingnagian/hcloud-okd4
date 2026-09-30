#!/usr/bin/env python3
"""Fail closed before teardown if a local state contains a different cluster."""
import json
from pathlib import Path
import sys


def check(path, domain, cluster):
    state = json.loads(Path(path).read_text())
    if not isinstance(state.get('resources'), list):
        raise ValueError('invalid Terraform state')
    for resource in state['resources']:
        if resource.get('mode') == 'data':
            continue
        for instance in resource.get('instances', []):
            attributes = instance.get('attributes', {})
            kind = resource['type']
            if kind in ('hcloud_server', 'hcloud_network', 'hcloud_load_balancer'):
                name = attributes.get('name', '')
                if name != domain and not name.endswith('.' + domain):
                    raise ValueError('Terraform state contains infrastructure outside the selected domain')
                owner = (attributes.get('labels') or {}).get('hcloud-okd4/cluster')
                if cluster and owner != cluster:
                    raise ValueError('Terraform state contains infrastructure without the selected cluster ownership label')
            if kind == 'hcloud_firewall' and not attributes.get('name', '').startswith(domain + '-'):
                raise ValueError('Terraform state contains a firewall outside the selected domain')
            if kind == 'hcloud_volume' and not attributes.get('name', '').endswith('.' + domain + '-data'):
                raise ValueError('Terraform state contains a volume outside the selected domain')
            if kind == 'cloudflare_dns_record':
                name = attributes.get('name', '')
                if name != domain and not name.endswith('.' + domain):
                    raise ValueError('Terraform state contains DNS outside the selected domain')


if __name__ == '__main__':
    try:
        check(*sys.argv[1:])
    except (OSError, ValueError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
