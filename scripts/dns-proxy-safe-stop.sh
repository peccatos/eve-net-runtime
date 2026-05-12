#!/usr/bin/env bash
set -euo pipefail

if systemctl list-unit-files eve-net-dns-proxy.service >/dev/null 2>&1; then
  sudo systemctl stop eve-net-dns-proxy.service || true
  sudo systemctl reset-failed eve-net-dns-proxy.service || true
  echo "eve-net-dns-proxy.service stopped/reset if it existed"
else
  echo "eve-net-dns-proxy.service is not installed/not loaded; nothing to stop"
fi
