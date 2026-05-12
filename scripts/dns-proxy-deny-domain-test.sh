#!/usr/bin/env bash
set -euo pipefail
BASE_CONFIG="${1:-/etc/eve-net/policy.json}"
DOMAIN="${2:-nonexistent-eve-net-test.invalid}"
UPSTREAM="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${EVE_NET_BIN:-/usr/local/bin/eve-net}"

if [[ ! -x "$BIN" ]]; then
  echo "eve-net binary not found: $BIN" >&2
  echo "install first: sudo bash scripts/install.sh" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'if [[ -n "${PID:-}" ]]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT
CONFIG="$TMP/policy.deny-test.json"
CACHE="$TMP/dns-cache.json"
PORT=5534
LISTEN="127.0.0.1:$PORT"

python3 - "$BASE_CONFIG" "$CONFIG" "$CACHE" "$LISTEN" "$DOMAIN" "$UPSTREAM" <<'PY'
import json, sys
from pathlib import Path
src, dst, cache, listen, domain, upstream = sys.argv[1:]
cfg = json.loads(Path(src).read_text())
cfg.setdefault('runtime', {})['dry_run'] = True
cfg.setdefault('dns_cache', {})
cfg['dns_cache']['path'] = cache
cfg['dns_cache']['enabled'] = True
cfg['dns_cache']['fail_closed_unresolved'] = True
cfg['dns_cache']['unresolved_domain_mode'] = 'hard_fail_closed_dns_required'
cfg['dns_cache']['dns_interception_enabled'] = True
cfg.setdefault('dns_interception', {})
cfg['dns_interception']['enabled'] = True
cfg['dns_interception']['listen_addr'] = listen
if upstream:
    cfg['dns_interception']['upstream_addr'] = upstream
cfg['dns_interception'].setdefault('upstream_addr', '111.88.96.50:53')
cfg['dns_interception']['cache_answers'] = True
cfg['dns_interception']['deny_unresolved_policy_domains'] = True
cfg['dns_interception']['deny_aaaa_for_policy_domains'] = True
cfg['dns_interception']['auto_redirect_enabled'] = False
policies = cfg.setdefault('policies', [])
policies = [p for p in policies if p.get('id') != 'deny-domain-self-test']
policies.append({
    'id': 'deny-domain-self-test',
    'enabled': True,
    'match': {'domain': domain},
    'action': {'egress': 'amn0'}
})
cfg['policies'] = policies
Path(dst).write_text(json.dumps(cfg, indent=2) + '\n')
print(cfg['dns_interception']['upstream_addr'])
PY

UPSTREAM_SELECTED="$(python3 - "$CONFIG" <<'PY'
import json,sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get('dns_interception',{}).get('upstream_addr',''))
PY
)"
echo "== DNS proxy deny-domain test =="
echo "domain: $DOMAIN"
echo "listen: $LISTEN"
echo "upstream: $UPSTREAM_SELECTED"

"$BIN" dns-proxy --config "$CONFIG" --apply >"$TMP/proxy.log" 2>&1 &
PID=$!
sleep 0.6
if ! kill -0 "$PID" 2>/dev/null; then
  echo "proxy failed to start"
  cat "$TMP/proxy.log"
  exit 3
fi

OUT="$(bash "$SCRIPT_DIR/dns-proxy-test.sh" "$DOMAIN" A "$LISTEN" || true)"
echo "$OUT"
echo
cat "$TMP/proxy.log" || true

if echo "$OUT" | grep -q 'rcode=5'; then
  echo "PASS: unresolved policy domain was DNS-refused by local proxy"
else
  echo "FAIL: expected rcode=5 REFUSED for unresolved policy domain" >&2
  exit 1
fi
