#!/usr/bin/env bash
set -euo pipefail

# Best-effort recovery when host DNS integration broke name resolution.
# Does not require a backup. It restores NetworkManager DNS to automatic mode
# for active non-loopback connections and stops eve-net DNS interception.

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/host-dns-emergency-restore.sh" >&2
  exit 1
fi

echo "== eve-net emergency host DNS restore =="

systemctl stop eve-net-dns-proxy.service 2>/dev/null || true
systemctl reset-failed eve-net-dns-proxy.service 2>/dev/null || true

echo "stopped eve-net-dns-proxy.service if it existed"

if command -v nmcli >/dev/null 2>&1; then
  echo "restoring active NetworkManager connections to automatic DNS"
  mapfile -t conns < <(nmcli -t -f NAME,TYPE,DEVICE connection show --active | awk -F: '$3 != "lo" && $2 != "loopback" {print $1}')
  if [[ ${#conns[@]} -eq 0 ]]; then
    echo "no active non-loopback NetworkManager connections found"
  fi
  for conn in "${conns[@]}"; do
    echo "  connection: $conn"
    nmcli connection modify "$conn" ipv4.ignore-auto-dns no ipv4.dns "" ipv4.dns-priority 0 || true
    nmcli connection modify "$conn" ipv6.ignore-auto-dns no ipv6.dns "" ipv6.dns-priority 0 || true
    nmcli connection up "$conn" || true
  done
fi

if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
  systemctl restart systemd-resolved.service 2>/dev/null || true
fi
systemctl restart NetworkManager.service 2>/dev/null || true

echo
if [[ -L /etc/resolv.conf ]]; then
  echo "resolv.conf symlink: $(readlink -f /etc/resolv.conf || readlink /etc/resolv.conf)"
else
  echo "resolv.conf is not a symlink; current content:"
fi
sed 's/^/  /' /etc/resolv.conf 2>/dev/null || true

echo
if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
  echo "ip connectivity: PASS"
else
  echo "ip connectivity: FAIL"
fi
if getent ahostsv4 example.com >/tmp/eve-net-emergency-dns.$$ 2>/dev/null; then
  echo "dns resolution: PASS"
  sed 's/^/  /' /tmp/eve-net-emergency-dns.$$ | head -5
else
  echo "dns resolution: FAIL"
  echo "manual fallback if Amnezia is active:"
  echo "  sudo nmcli con mod <CONNECTION> ipv4.ignore-auto-dns yes ipv4.dns '111.88.96.50 111.88.96.51'"
  echo "  sudo nmcli con up <CONNECTION>"
fi
rm -f /tmp/eve-net-emergency-dns.$$
