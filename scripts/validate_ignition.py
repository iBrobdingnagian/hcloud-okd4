#!/usr/bin/env python3
"""Validate rendered Ignition JSON and reject duplicate keys before provisioning."""
import json
from pathlib import Path
import sys


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def validate(path):
    data = json.loads(Path(path).read_text(), object_pairs_hook=unique_pairs)
    version = data.get('ignition', {}).get('version', '')
    if not version.startswith('3.'):
        raise ValueError(f'{path}: expected Ignition v3')
    # Pointer configs need a source, and fully rendered configs may use storage/systemd instead.
    for merge in data.get('ignition', {}).get('config', {}).get('merge', []):
        if not merge.get('source'):
            raise ValueError(f'{path}: empty ignition merge source')


if __name__ == '__main__':
    try:
        if len(sys.argv) < 2:
            raise ValueError('at least one rendered ignition file is required')
        for filename in sys.argv[1:]:
            validate(filename)
    except (OSError, ValueError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
