#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
BIN="${EVE_NET_BIN:-/usr/local/bin/eve-net}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/reload-policy.sh [config]" >&2
  exit 1
fi

if [[ ! -x "$BIN" ]]; then
  echo "eve-net binary not found or not executable: $BIN" >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "config not found: $CONFIG" >&2
  exit 1
fi

echo "Stopping eve-net.service to avoid concurrent reconcile..."
systemctl stop eve-net.service 2>/dev/null || true

echo "Reconciling policy once..."
"$BIN" reconcile --config "$CONFIG" --apply

echo "Starting eve-net.service..."
systemctl start eve-net.service

echo
"$BIN" status --config "$CONFIG"
