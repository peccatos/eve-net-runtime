#!/usr/bin/env bash
set -euo pipefail
CONFIG="${1:-/etc/eve-net/policy.json}"
DOMAIN="${2:-example.com}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTEN="$(python3 - "$CONFIG" <<'PY'
import json, sys
from pathlib import Path
cfg=json.loads(Path(sys.argv[1]).read_text())
print(cfg.get('dns_interception', {}).get('listen_addr', '127.0.0.1:5533'))
PY
)"

echo "== AAAA deny test =="
echo "domain: $DOMAIN"
echo "server: $LISTEN"
if ! systemctl is-active --quiet eve-net-dns-proxy.service; then
  echo "dns proxy service is inactive; start it first: sudo systemctl start eve-net-dns-proxy.service" >&2
  exit 2
fi

OUT="$(bash "$SCRIPT_DIR/dns-proxy-test.sh" "$DOMAIN" AAAA "$LISTEN" || true)"
echo "$OUT"
if echo "$OUT" | grep -q 'rcode=5'; then
  echo "PASS: AAAA query was refused for policy domain"
else
  echo "FAIL: expected rcode=5 REFUSED for AAAA policy-domain query" >&2
  exit 1
fi
