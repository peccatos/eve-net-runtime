#!/usr/bin/env bash
set -euo pipefail

FORCE="${1:-}"

uses_local_dns=false
if grep -qE '^nameserver[[:space:]]+127\.0\.0\.1$' /etc/resolv.conf 2>/dev/null; then
  uses_local_dns=true
fi
if command -v nmcli >/dev/null 2>&1; then
  if nmcli -t -f IP4.DNS device show 2>/dev/null | grep -q '127\.0\.0\.1'; then
    uses_local_dns=true
  fi
fi

if [[ "$uses_local_dns" == true && "$FORCE" != "--force" ]]; then
  cat >&2 <<'MSG'
REFUSING: host DNS appears to point to 127.0.0.1.
Stopping eve-net-dns-proxy.service may break DNS.
Use rollback first:
  sudo bash scripts/host-dns-rollback.sh
Or emergency restore:
  sudo bash scripts/host-dns-emergency-restore.sh
Or force stop:
  sudo bash scripts/host-dns-safe-stop.sh --force
MSG
  exit 1
fi

sudo systemctl stop eve-net-dns-proxy.service 2>/dev/null || true
sudo systemctl reset-failed eve-net-dns-proxy.service 2>/dev/null || true
echo "eve-net-dns-proxy.service stopped/reset if it existed"
