#!/usr/bin/env bash
set -euo pipefail
CONFIG="${1:-/etc/eve-net/policy.json}"
DOMAIN="${2:-example.com}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read_json_field() {
  local expr="$1"
  python3 - "$CONFIG" "$expr" <<'PY'
import json, sys
from pathlib import Path
cfg = json.loads(Path(sys.argv[1]).read_text())
expr = sys.argv[2]
cur = cfg
for part in expr.split('.'):
    cur = cur.get(part, {}) if isinstance(cur, dict) else {}
print(cur if isinstance(cur, str) else "")
PY
}

LISTEN="$(read_json_field dns_interception.listen_addr)"
UPSTREAM="$(read_json_field dns_interception.upstream_addr)"
LISTEN="${LISTEN:-127.0.0.1:5533}"
UPSTREAM="${UPSTREAM:-111.88.96.50:53}"
PORT="${LISTEN##*:}"

echo "== eve-net DNS proxy self-test =="
echo "config: $CONFIG"
echo "domain: $DOMAIN"
echo "listen: $LISTEN"
echo "upstream: $UPSTREAM"

echo
echo "== port check =="
bash "$SCRIPT_DIR/dns-proxy-port-check.sh" "$PORT" || true

echo
echo "== upstream policy check =="
bash "$SCRIPT_DIR/dns-upstream-policy-check.sh" "$CONFIG" || true

echo
echo "== upstream direct test =="
bash "$SCRIPT_DIR/dns-upstream-test.sh" "$UPSTREAM" "$DOMAIN"

echo
echo "== service status =="
if systemctl is-active --quiet eve-net-dns-proxy.service; then
  echo "dns proxy service: active"
else
  echo "dns proxy service: inactive; start with: sudo systemctl start eve-net-dns-proxy.service" >&2
  exit 2
fi

echo
echo "== proxy A query test =="
bash "$SCRIPT_DIR/dns-proxy-test.sh" "$DOMAIN" A "$LISTEN"

echo
echo "== proxy AAAA deny test =="
bash "$SCRIPT_DIR/dns-proxy-aaaa-deny-test.sh" "$CONFIG" "$DOMAIN"

echo
echo "== cache write verification =="
bash "$SCRIPT_DIR/dns-proxy-cache-write-test.sh" "$CONFIG" "$DOMAIN"

echo
echo "== unresolved deny-domain self-test =="
bash "$SCRIPT_DIR/dns-proxy-deny-domain-test.sh" "$CONFIG" "nonexistent-eve-net-test.invalid" "$UPSTREAM"

echo
echo "DNS proxy self-test: PASS"
