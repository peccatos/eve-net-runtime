#!/usr/bin/env bash
set -euo pipefail
CONFIG="${1:-/etc/eve-net/policy.json}"

echo "== eve-net DNS proxy service =="
if systemctl list-unit-files eve-net-dns-proxy.service >/dev/null 2>&1; then
  systemctl status eve-net-dns-proxy.service --no-pager -l || true
else
  echo "eve-net-dns-proxy.service: not installed/not loaded"
fi

echo
if command -v eve-net >/dev/null 2>&1; then
  sudo /usr/local/bin/eve-net dns-intercept-status --config "$CONFIG" || true
else
  echo "eve-net binary not found at /usr/local/bin/eve-net"
fi

echo
bash "$(dirname "$0")/dns-proxy-port-check.sh" 5533 || true
