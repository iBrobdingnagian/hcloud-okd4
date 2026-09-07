#!/usr/bin/env bash
#
# reboot-okd.sh — reboot the OKD cluster VMs on Hetzner.
# Thin wrapper around power-okd.sh; every option is passed through
# (--role, --hard, --wait, --yes, server names). See ./power-okd.sh --help
#
set -euo pipefail
cd "$(dirname "$0")"
exec ./power-okd.sh reboot "$@"
