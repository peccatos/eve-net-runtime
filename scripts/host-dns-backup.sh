#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${1:-/var/lib/eve-net/host-dns-backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DIR="$BACKUP_ROOT/$STAMP"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/host-dns-backup.sh" >&2
  exit 1
fi

install -d -m 700 "$DIR"

{
  echo "created_at=$STAMP"
  echo "hostname=$(hostname 2>/dev/null || true)"
} > "$DIR/meta.env"

if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then
  cp -a /etc/resolv.conf "$DIR/resolv.conf.backup" 2>/dev/null || true
  readlink /etc/resolv.conf > "$DIR/resolv.conf.link" 2>/dev/null || true
  readlink -f /etc/resolv.conf > "$DIR/resolv.conf.link_abs" 2>/dev/null || true
  sed -n '1,200p' /etc/resolv.conf > "$DIR/resolv.conf.content" 2>/dev/null || true
fi

if command -v resolvectl >/dev/null 2>&1; then
  resolvectl status > "$DIR/resolvectl.status" 2>&1 || true
  resolvectl dns > "$DIR/resolvectl.dns" 2>&1 || true
fi

if command -v nmcli >/dev/null 2>&1; then
  nmcli -t -f NAME,UUID,TYPE,DEVICE connection show --active > "$DIR/nm-active.tsv" 2>/dev/null || true
  active="$(awk -F: '$4 != "lo" && $3 != "loopback" {print $1; exit}' "$DIR/nm-active.tsv" 2>/dev/null || true)"
  if [[ -n "${active:-}" ]]; then
    echo "$active" > "$DIR/nm-primary-name"
    nmcli connection show "$active" > "$DIR/nm-primary-full.txt" 2>&1 || true
    for key in ipv4.ignore-auto-dns ipv4.dns ipv4.dns-priority ipv6.ignore-auto-dns ipv6.dns ipv6.dns-priority; do
      safe="${key//./_}"
      nmcli -g "$key" connection show "$active" > "$DIR/nm-$safe" 2>/dev/null || true
    done
  fi
fi

echo "$DIR"
