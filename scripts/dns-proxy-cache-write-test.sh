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

echo "== DNS proxy cache-write test =="
echo "domain: $DOMAIN"
echo "server: $LISTEN"
if ! systemctl is-active --quiet eve-net-dns-proxy.service; then
  echo "dns proxy service is inactive; start it first: sudo systemctl start eve-net-dns-proxy.service" >&2
  exit 2
fi

bash "$SCRIPT_DIR/dns-proxy-test.sh" "$DOMAIN" A "$LISTEN"

echo
CACHE_OUT="$(sudo /usr/local/bin/eve-net dns-cache --config "$CONFIG")"
echo "$CACHE_OUT"
if echo "$CACHE_OUT" | grep -q "domain: $DOMAIN" && echo "$CACHE_OUT" | grep -q 'state: FRESH'; then
  echo "PASS: DNS cache contains fresh entry for $DOMAIN"
else
  echo "FAIL: DNS cache does not show fresh entry for $DOMAIN" >&2
  exit 1
fi
