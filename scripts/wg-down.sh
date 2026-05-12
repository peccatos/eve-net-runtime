#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:?usage: sudo bash scripts/wg-down.sh wg0|wg1}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/wg-down.sh $IFACE" >&2
  exit 1
fi

if [[ ! "$IFACE" =~ ^wg[0-9]+$ ]]; then
  echo "Refusing suspicious interface name: $IFACE" >&2
  exit 1
fi

wg-quick down "$IFACE" || true
