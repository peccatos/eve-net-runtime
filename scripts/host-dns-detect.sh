#!/usr/bin/env bash
set -euo pipefail

echo "== eve-net host DNS detect =="

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet systemd-resolved.service; then
    echo "systemd_resolved: active"
  else
    echo "systemd_resolved: inactive_or_missing"
  fi
fi

if command -v nmcli >/dev/null 2>&1; then
  echo "network_manager: available"
  echo
  echo "active_nm_connections:"
  nmcli -t -f NAME,UUID,TYPE,DEVICE connection show --active | sed 's/^/  - /' || true
else
  echo "network_manager: missing"
fi

echo
if [[ -L /etc/resolv.conf ]]; then
  echo "resolv_conf: symlink -> $(readlink -f /etc/resolv.conf || readlink /etc/resolv.conf)"
else
  echo "resolv_conf: regular_file_or_other"
fi

echo "resolv_conf_content:"
sed 's/^/  /' /etc/resolv.conf 2>/dev/null || true

echo
if command -v resolvectl >/dev/null 2>&1; then
  echo "resolvectl_dns:"
  resolvectl dns 2>/dev/null | sed 's/^/  /' || true
else
  echo "resolvectl: missing"
fi

echo
if command -v ss >/dev/null 2>&1; then
  echo "dns_listeners_53_5533:"
  ss -ulpn 2>/dev/null | grep -E ':(53|5533)\b' | sed 's/^/  /' || echo "  none"
fi

echo
cat <<'NOTE'
notes:
  - /etc/resolv.conf and NetworkManager DNS fields cannot specify port 5533.
  - Host-wide DNS integration needs eve-net DNS proxy on 127.0.0.1:53.
  - v0.11 does not apply host DNS changes unless a script is run with --apply.
NOTE
