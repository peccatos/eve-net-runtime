#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"

if [[ -x /usr/local/bin/eve-net ]]; then
  sudo /usr/local/bin/eve-net wg-status --config "$CONFIG"
else
  cargo run -- wg-status --config "$CONFIG"
fi

echo
echo "== kernel links =="
ip -br link show type wireguard 2>/dev/null || true

echo
echo "== raw wg show =="
sudo wg show || true
