#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/install-wireguard-templates.sh" >&2
  exit 1
fi

install -d -m 700 /etc/wireguard
install -m 600 config/wireguard/wg0.conf.template /etc/wireguard/eve-net-wg0.conf.template
install -m 600 config/wireguard/wg1.conf.template /etc/wireguard/eve-net-wg1.conf.template

cat <<'MSG'
Installed WireGuard templates:
  /etc/wireguard/eve-net-wg0.conf.template
  /etc/wireguard/eve-net-wg1.conf.template

Next:
  sudo cp /etc/wireguard/eve-net-wg0.conf.template /etc/wireguard/wg0.conf
  sudo nano /etc/wireguard/wg0.conf
  sudo chmod 600 /etc/wireguard/wg0.conf
  sudo wg-quick up wg0
MSG
