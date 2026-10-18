#!/usr/bin/env python3
"""Validate a Red Hat registry pull secret, optionally copy it into install config."""
import json
import os
from pathlib import Path
import sys
import yaml


def validate_pull_secret(secret):
    if isinstance(secret, str):
        secret = json.loads(secret)
    auths = secret.get('auths', {})
    if not any(isinstance(auths.get(host), dict) and
               (auths[host].get('auth') not in (None, '', 'none') or auths[host].get('identitytoken'))
               for host in ('quay.io', 'registry.redhat.io', 'cloud.openshift.com')):
        raise ValueError('Red Hat pull-secret JSON must contain registry credentials; OKD dummy secrets cannot be used')
    return secret


def main():
    try:
        path = Path(sys.argv[1])
        config = yaml.safe_load(path.read_text())
        file = sys.argv[2]
        secret = validate_pull_secret(Path(file).read_text() if file else config.get('pullSecret', '{}'))
        if file:
            config['pullSecret'] = json.dumps(secret)
            path.chmod(0o600)
            temporary = path.with_name(path.name + '.tmp')
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream:
                yaml.safe_dump(config, stream)
            temporary.replace(path)
    except (OSError, ValueError, TypeError, AttributeError, IndexError):
        print('A valid Red Hat pull secret is required (contents are never logged).', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
