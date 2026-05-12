#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
BIN="${EVE_NET_BIN:-/usr/local/bin/eve-net}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/reconcile-once.sh [config]" >&2
  exit 1
fi

"$BIN" reconcile --config "$CONFIG" --apply
