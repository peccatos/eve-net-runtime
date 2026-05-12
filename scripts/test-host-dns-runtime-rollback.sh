#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
SNAPSHOT=""
RESTORE_DONE=0
FAIL_PRINTED=0

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/test-host-dns-runtime-rollback.sh /etc/eve-net/policy.json" >&2
  exit 1
fi

fail() {
  FAIL_PRINTED=1
  echo "FAIL: $*" >&2
  if [[ -n "$SNAPSHOT" && "$RESTORE_DONE" != "1" ]]; then
    bash scripts/host-dns-runtime-restore.sh "$SNAPSHOT" || true
  fi
  exit 1
}

on_exit() {
  local code=$?
  if [[ "$code" -ne 0 && "$FAIL_PRINTED" != "1" ]]; then
    echo "FAIL: unexpected error" >&2
    if [[ -n "$SNAPSHOT" && "$RESTORE_DONE" != "1" ]]; then
      bash scripts/host-dns-runtime-restore.sh "$SNAPSHOT" || true
    fi
  fi
}

trap on_exit EXIT

snapshot_has_dns_servers() {
  python3 - "$SNAPSHOT" <<'PY'
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text())
links = snapshot.get("links", {})
has_dns = any(bool(state.get("dns_servers")) for state in links.values())
raise SystemExit(0 if has_dns else 1)
PY
}

host_dns_has_some_capability() {
  resolvectl query -t A example.com >/dev/null 2>&1 || getent ahostsv4 example.com >/dev/null 2>&1
}

validate_domain() {
  local domain="$1"
  resolvectl query -t A "$domain" >/dev/null 2>&1 || return 1
  getent ahostsv4 "$domain" >/dev/null 2>&1 || return 1
}

SNAPSHOT="$(bash scripts/host-dns-runtime-snapshot.sh "$CONFIG")"
echo "snapshot: $SNAPSHOT"

bash scripts/dns-proxy-test.sh example.com A 127.0.0.1:53 || fail "local DNS proxy on 127.0.0.1:53 is not usable"

links=(wlo1)
if [[ -d /sys/class/net/amn0 ]]; then
  links+=(amn0)
fi

for link in "${links[@]}"; do
  resolvectl dns "$link" 127.0.0.1 || fail "failed to set DNS for $link"
  resolvectl domain "$link" '~.' || fail "failed to set domain for $link"
  resolvectl default-route "$link" yes || fail "failed to set default-route for $link"
done
resolvectl flush-caches || true

validate_domain example.com || fail "example.com validation failed after safe runtime DNS apply"
validate_domain openai.com || fail "openai.com validation failed after safe runtime DNS apply"

bash scripts/host-dns-runtime-restore.sh "$SNAPSHOT" || fail "snapshot restore failed"
RESTORE_DONE=1

if host_dns_has_some_capability; then
  echo "post-restore DNS capability: PASS"
elif ! snapshot_has_dns_servers; then
  echo "post-restore DNS capability failed; snapshot had no DNS servers, running repair"
  bash scripts/host-dns-runtime-repair.sh "$CONFIG" || fail "repair failed after empty snapshot restore"
  host_dns_has_some_capability || fail "DNS capability still failed after repair"
else
  fail "post-restore DNS capability failed"
fi

echo "PASS"
