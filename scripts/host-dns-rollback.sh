#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT_ROOT="/var/lib/eve-net/host-dns-runtime-snapshots"
SNAPSHOT=""
REPAIR=0
LATEST=0
LEGACY_REVERT=0
LEGACY_BACKUP_DIR=""
CONFIG="/etc/eve-net/policy.json"

usage() {
  cat <<'MSG'
Usage:
  sudo bash scripts/host-dns-rollback.sh [--latest]
  sudo bash scripts/host-dns-rollback.sh --snapshot /var/lib/eve-net/host-dns-runtime-snapshots/<timestamp>.json
  sudo bash scripts/host-dns-rollback.sh --repair
  sudo bash scripts/host-dns-rollback.sh --legacy-revert [legacy_backup_dir]

Warning:
  legacy revert is unsafe on Fedora/systemd-resolved/NetworkManager/Amnezia setups
MSG
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot)
      SNAPSHOT="${2:-}"
      shift 2
      ;;
    --latest)
      LATEST=1
      shift
      ;;
    --repair)
      REPAIR=1
      shift
      ;;
    --legacy-revert)
      LEGACY_REVERT=1
      shift
      ;;
    --config)
      CONFIG="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -f "$1" ]]; then
        SNAPSHOT="$1"
      elif [[ -d "$1" ]]; then
        LEGACY_BACKUP_DIR="$1"
      else
        echo "unknown argument: $1" >&2
        usage >&2
        exit 64
      fi
      shift
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/host-dns-rollback.sh [--latest|--snapshot <path>|--repair|--legacy-revert]" >&2
  exit 1
fi

latest_snapshot() {
  find "$SNAPSHOT_ROOT" -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -n \
    | tail -n 1 \
    | cut -d' ' -f2-
}

host_dns_ok() {
  resolvectl query -t A example.com >/dev/null 2>&1 && getent ahostsv4 example.com >/dev/null 2>&1
}

legacy_read_key() {
  local file="$1"
  [[ -f "$file" ]] && cat "$file" || true
}

legacy_nm_restore() {
  local backup_dir="$1"

  if [[ -z "$backup_dir" && -f /var/lib/eve-net/host-dns-last-backup ]]; then
    backup_dir="$(cat /var/lib/eve-net/host-dns-last-backup)"
  fi

  if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
    echo "no legacy backup directory available" >&2
    return 0
  fi

  echo "legacy rollback backup: $backup_dir"

  if [[ -f "$backup_dir/nm-primary-name" ]] && command -v nmcli >/dev/null 2>&1; then
    CONN="$(cat "$backup_dir/nm-primary-name")"
    echo "restoring NetworkManager connection: $CONN"
    v4ignore="$(legacy_read_key "$backup_dir/nm-ipv4_ignore-auto-dns")"
    v4dns="$(legacy_read_key "$backup_dir/nm-ipv4_dns")"
    v4prio="$(legacy_read_key "$backup_dir/nm-ipv4_dns-priority")"
    v6ignore="$(legacy_read_key "$backup_dir/nm-ipv6_ignore-auto-dns")"
    v6dns="$(legacy_read_key "$backup_dir/nm-ipv6_dns")"
    v6prio="$(legacy_read_key "$backup_dir/nm-ipv6_dns-priority")"

    [[ -n "$v4ignore" ]] && nmcli connection modify "$CONN" ipv4.ignore-auto-dns "$v4ignore" || true
    if [[ -n "$v4dns" ]]; then
      nmcli connection modify "$CONN" ipv4.dns "$v4dns" || true
    else
      nmcli connection modify "$CONN" ipv4.dns "" || true
    fi
    [[ -n "$v4prio" ]] && nmcli connection modify "$CONN" ipv4.dns-priority "$v4prio" || true
    [[ -n "$v6ignore" ]] && nmcli connection modify "$CONN" ipv6.ignore-auto-dns "$v6ignore" || true
    if [[ -n "$v6dns" ]]; then
      nmcli connection modify "$CONN" ipv6.dns "$v6dns" || true
    else
      nmcli connection modify "$CONN" ipv6.dns "" || true
    fi
    [[ -n "$v6prio" ]] && nmcli connection modify "$CONN" ipv6.dns-priority "$v6prio" || true
    nmcli connection up "$CONN" || true
  fi

  if [[ -f "$backup_dir/resolv.conf.backup" && ! -L /etc/resolv.conf ]]; then
    echo "restoring regular /etc/resolv.conf"
    cp -a "$backup_dir/resolv.conf.backup" /etc/resolv.conf
  fi
}

legacy_revert_links() {
  echo "WARNING: legacy revert is unsafe on Fedora/systemd-resolved/NetworkManager/Amnezia setups" >&2
  legacy_nm_restore "$LEGACY_BACKUP_DIR"
  if command -v resolvectl >/dev/null 2>&1; then
    for link in wlo1 amn0; do
      if [[ -d "/sys/class/net/$link" ]]; then
        resolvectl revert "$link" || true
      fi
    done
    resolvectl flush-caches || true
  fi
  echo "legacy rollback finished"
}

if [[ "$LEGACY_REVERT" == "1" ]]; then
  legacy_revert_links
  exit 0
fi

if [[ -z "$SNAPSHOT" ]]; then
  SNAPSHOT="$(latest_snapshot || true)"
fi

if [[ -z "$SNAPSHOT" || ! -f "$SNAPSHOT" ]]; then
  echo "no runtime DNS snapshot found under $SNAPSHOT_ROOT" >&2
  echo "repair command:" >&2
  echo "  sudo bash scripts/host-dns-runtime-repair.sh /etc/eve-net/policy.json" >&2
  if [[ "$REPAIR" == "1" ]]; then
    bash scripts/host-dns-runtime-repair.sh "$CONFIG"
    exit 0
  fi
  exit 1
fi

echo "runtime rollback snapshot: $SNAPSHOT"
bash scripts/host-dns-runtime-restore.sh "$SNAPSHOT"

if [[ "$REPAIR" == "1" ]]; then
  if host_dns_ok; then
    echo "host DNS validation after restore: PASS"
  else
    echo "host DNS validation after restore: FAIL; running repair"
    bash scripts/host-dns-runtime-repair.sh "$CONFIG"
  fi
fi

echo "rollback finished"
