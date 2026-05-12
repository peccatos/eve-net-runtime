#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/refresh-direct-egress.sh /etc/eve-net/policy.json" >&2
  exit 1
fi

exec sudo /usr/local/bin/eve-net refresh-direct-egress --config "$CONFIG" --apply
