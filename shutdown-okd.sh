#!/usr/bin/env bash
#
# shutdown-okd.sh — power the OKD cluster VMs down on Hetzner.
# Thin wrapper around power-okd.sh; every option is passed through
# (--role, --hard, --wait, --yes, server names). See ./power-okd.sh --help
#
# The servers keep their disks and are billed while stopped — this is a
# pause, not a teardown. Bring them back with:
#     ./power-okd.sh poweron
# To actually delete the infrastructure use ./destroy-okd.sh instead.
#
set -euo pipefail
cd "$(dirname "$0")"
exec ./power-okd.sh shutdown "$@"
