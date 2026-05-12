#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/uninstall.sh" >&2
  exit 1
fi

KEEP_CONFIG="${KEEP_CONFIG:-1}"

systemctl stop eve-net.service 2>/dev/null || true
systemctl stop eve-net-cleanup.service 2>/dev/null || true
systemctl stop eve-net-status.service 2>/dev/null || true
systemctl stop eve-net-dns-refresh.timer 2>/dev/null || true
systemctl stop eve-net-dns-prune.timer 2>/dev/null || true
systemctl stop eve-net-dns-refresh.service 2>/dev/null || true
systemctl stop eve-net-dns-prune.service 2>/dev/null || true
systemctl stop eve-net-dns-proxy.service 2>/dev/null || true
systemctl disable eve-net.service 2>/dev/null || true
systemctl disable eve-net-dns-refresh.timer 2>/dev/null || true
systemctl disable eve-net-dns-prune.timer 2>/dev/null || true
systemctl disable eve-net-dns-proxy.service 2>/dev/null || true

if [[ -x /usr/local/bin/eve-net && -f /etc/eve-net/policy.json ]]; then
  /usr/local/bin/eve-net cleanup --config /etc/eve-net/policy.json --apply --verbose || true
fi

rm -f /etc/systemd/system/eve-net.service
rm -f /etc/systemd/system/eve-net-cleanup.service
rm -f /etc/systemd/system/eve-net-status.service
rm -f /etc/systemd/system/eve-net-dns-refresh.service
rm -f /etc/systemd/system/eve-net-dns-refresh.timer
rm -f /etc/systemd/system/eve-net-dns-prune.service
rm -f /etc/systemd/system/eve-net-dns-prune.timer
rm -f /etc/systemd/system/eve-net-dns-proxy.service
systemctl daemon-reload
systemctl reset-failed eve-net.service eve-net-cleanup.service eve-net-status.service eve-net-dns-refresh.service eve-net-dns-refresh.timer eve-net-dns-prune.service eve-net-dns-prune.timer eve-net-dns-proxy.service 2>/dev/null || true

rm -f /usr/local/bin/eve-net
rm -rf /usr/share/doc/eve-net

if [[ "$KEEP_CONFIG" == "0" ]]; then
  rm -rf /etc/eve-net
  echo "Removed /etc/eve-net"
else
  echo "Kept /etc/eve-net. To remove it: sudo KEEP_CONFIG=0 bash scripts/uninstall.sh"
fi

echo "Uninstalled eve-net."
