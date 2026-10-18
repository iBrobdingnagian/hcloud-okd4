#!/usr/bin/env python3
"""List the newest stable numeric patch in each Red Hat mirror release line."""
import re
import sys
import urllib.request

MIRROR = 'https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/'


def release_choices(html):
    versions = sorted(set(re.findall(r'href=[\"\'](4\.[0-9]+\.[0-9]+)/[\"\']', html)),
                      key=lambda value: tuple(map(int, value.split('.'))), reverse=True)
    lines = {}
    for version in versions:
        lines.setdefault('.'.join(version.split('.')[:2]), version)
    return list(lines.values())[:8]


if __name__ == '__main__':
    try:
        with urllib.request.urlopen(MIRROR, timeout=30) as response:
            choices = release_choices(response.read().decode())
        if not choices:
            raise ValueError('No numeric releases found')
        print('\n'.join(choices))
    except (OSError, ValueError) as exc:
        print('Cannot list Red Hat releases; specify an exact --release instead.', file=sys.stderr)
        sys.exit(1)
