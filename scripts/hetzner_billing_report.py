#!/usr/bin/env python3
"""Render actual Hetzner Console project consumption; never estimate resource costs.

The public Cloud API token does not provide this usage table. Capture current
values from the signed-in https://console.hetzner.com/usage page into usage.json.
"""
import argparse
import csv
from datetime import datetime, timezone
from decimal import Decimal
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def write_report(source, out):
    if source.get('source') != 'https://console.hetzner.com/usage':
        raise ValueError('Expected an actual Hetzner Console usage snapshot')
    if not re.fullmatch(r'\d{4}-(0[1-9]|1[0-2])', source['period']):
        raise ValueError('period must be YYYY-MM')
    rows = []
    for project in source['projects']:
        amount = Decimal(project['amount'])
        if not amount.is_finite() or amount < 0:
            raise ValueError('Project amounts must be finite and nonnegative')
        rows.append(dict(name=project['name'], consumption=str(amount)))
    total = sum((Decimal(r['consumption']) for r in rows), Decimal(0))
    if not Decimal(source['total']).is_finite() or total != Decimal(source['total']):
        raise ValueError('Project consumption does not match the console total')
    captured = source.get('captured_at')
    if not captured:
        raise ValueError('captured_at is required to identify snapshot freshness')
    capture_time = datetime.fromisoformat(captured.replace('Z', '+00:00'))
    if capture_time.utcoffset() is None:
        raise ValueError('captured_at must include a timezone')
    if source.get('tax_basis') not in (None, 'inclusive', 'exclusive'):
        raise ValueError('tax_basis must be inclusive or exclusive when supplied')
    data = dict(source, rows=rows, generated_at=datetime.now(timezone.utc).isoformat())
    out.mkdir(parents=True, exist_ok=True)
    (out/'billing.json').write_text(json.dumps(data, indent=2)+'\n')
    with (out/'billing.csv').open('w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['period', 'project', 'currency', 'current_consumption'])
        for row in rows:
            name = row['name']
            if name.startswith(('=', '+', '-', '@', '\t', '\r')):
                name = "'" + name
            writer.writerow([source['period'], name, source['currency'], row['consumption']])
    embedded = json.dumps(data).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    template = Path(__file__).with_suffix('.html').read_text()
    (out/'index.html').write_text(template.replace('__BILLING_DATA__', embedded))
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, default=ROOT/'report/usage.json')
    parser.add_argument('--output', type=Path, default=ROOT/'report')
    args = parser.parse_args()
    try:
        data = write_report(json.loads(args.input.read_text()), args.output)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'Error: {exc}', file=sys.stderr)
        return 1
    print(f'Saved consumption: {data["total"]} {data["currency"]} ({data["period"]})')
    print(f'Captured: {data["captured_at"]}; regeneration does not refresh usage')
    print(f'Report: {(args.output/"index.html").resolve()}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
