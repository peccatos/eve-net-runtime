#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:?usage: sudo bash scripts/wg-up.sh wg0|wg1}"
CONF="/etc/wireguard/${IFACE}.conf"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/wg-up.sh $IFACE" >&2
  exit 1
fi

if [[ ! "$IFACE" =~ ^wg[0-9]+$ ]]; then
  echo "Refusing suspicious interface name: $IFACE" >&2
  exit 1
fi

if [[ ! -f "$CONF" ]]; then
  echo "Missing $CONF" >&2
  echo "Use: sudo cp /etc/wireguard/eve-net-${IFACE}.conf.template $CONF" >&2
  exit 1
fi

wg-quick up "$IFACE"
wg show "$IFACE"
