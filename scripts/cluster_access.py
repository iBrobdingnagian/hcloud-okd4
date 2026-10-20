#!/usr/bin/env python3
"""Keep workstation kubeconfigs usable across snapshot load-balancer changes."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlsplit

import yaml

from check_state import check as check_state


def load_balancer_ip(state, domain):
    addresses = [
        instance['attributes']['ipv4']
        for resource in state.get('resources', [])
        if resource.get('mode', 'managed') == 'managed'
        and resource.get('type') == 'hcloud_load_balancer'
        for instance in resource.get('instances', [])
        if instance.get('attributes', {}).get('name') == 'lb.' + domain
    ]
    if len(addresses) != 1:
        raise ValueError('Cannot identify exactly one managed load balancer for ' + domain)
    return str(ipaddress.IPv4Address(addresses[0]))


def selected_cluster(config):
    contexts = [entry['context'] for entry in config.get('contexts', [])
                if entry.get('name') == config.get('current-context')]
    if len(contexts) != 1:
        raise ValueError('Kubeconfig must select exactly one context')
    clusters = [entry['cluster'] for entry in config.get('clusters', [])
                if entry.get('name') == contexts[0].get('cluster')]
    if len(clusters) != 1:
        raise ValueError('Kubeconfig must select exactly one cluster')
    return clusters[0]


def validate_identity(config, domain, address=None, allow_previous_ip=False):
    """Accept the DNS identity or a TLS-verified endpoint owned by this state.

    Refresh alone may accept a previous LB address: restored artifacts can contain
    the address from before teardown. Its TLS name must still identify this domain.
    """
    cluster = selected_cluster(config)
    hostname = 'api.' + domain
    server = cluster.get('server', '')
    tls_name = cluster.get('tls-server-name')
    if cluster.get('insecure-skip-tls-verify'):
        raise ValueError('Kubeconfig disables TLS certificate verification')
    if server == f'https://{hostname}:6443' and tls_name in (None, '', hostname):
        return cluster
    endpoint = urlsplit(server)
    try:
        ip = str(ipaddress.IPv4Address(endpoint.hostname))
    except (ValueError, TypeError):
        ip = None
    if (ip and server == f'https://{ip}:6443' and tls_name == hostname
            and (ip == address or allow_previous_ip)):
        return cluster
    raise ValueError('Kubeconfig does not belong to ' + domain)


def refresh(work, domain):
    work = Path(work)
    state = json.loads((work / 'terraform/terraform.tfstate').read_text())
    address = load_balancer_ip(state, domain)
    path = work / 'ignition/auth/kubeconfig'
    if path.is_symlink():
        raise ValueError('Installer kubeconfig must not be a symlink')
    config = yaml.safe_load(path.read_text())
    cluster = validate_identity(config, domain, address, allow_previous_ip=True)
    # Credentials, trust roots, contexts, and all other clusters remain intact.
    cluster.update(server=f'https://{address}:6443', **{'tls-server-name': 'api.' + domain})
    # Atomic replacement prevents dashboard/CLI readers seeing a partial config.
    fd, temporary = tempfile.mkstemp(prefix='.kubeconfig-', dir=path.parent)
    temporary = Path(temporary)
    try:
        with os.fdopen(fd, 'w') as stream:
            yaml.safe_dump(config, stream, sort_keys=False)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return address


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('refresh', 'validate'))
    parser.add_argument('work', type=Path)
    parser.add_argument('domain')
    parser.add_argument('--kubeconfig', type=Path)
    args = parser.parse_args()
    state_path = args.work / 'terraform/terraform.tfstate'
    check_state(state_path, args.domain, os.environ.get('CLUSTER_ID', ''))
    if args.operation == 'refresh':
        address = refresh(args.work, args.domain)
        print(f'CLI endpoint: https://{address}:6443 (TLS identity: api.{args.domain})')
    else:
        address = load_balancer_ip(json.loads(state_path.read_text()), args.domain)
        path = args.kubeconfig or args.work / 'ignition/auth/kubeconfig'
        validate_identity(yaml.safe_load(path.read_text()), args.domain, address)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, AttributeError, yaml.YAMLError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
