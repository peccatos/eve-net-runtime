#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
DOMAIN="${2:-example.com}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -f "$CONFIG" ]]; then
  echo "missing config: $CONFIG" >&2
  exit 1
fi

mapfile -t CONFIG_LINES < <(python3 - "$CONFIG" <<'PY'
import ipaddress
import json
import sys
from pathlib import Path

cfg = json.loads(Path(sys.argv[1]).read_text())
dns = cfg.get("dns_interception", {})


def valid(value):
    if not isinstance(value, str):
        return False
    value = value.strip()
    try:
        if value.startswith("["):
            host, port_text = value.rsplit("]:", 1)
            host = host[1:]
        else:
            host, port_text = value.rsplit(":", 1)
            if ":" in host:
                return False
        ipaddress.ip_address(host)
        port = int(port_text)
        return 1 <= port <= 65535
    except Exception:
        return False


listen = dns.get("listen_addr", "127.0.0.1:5533")
entries = dns.get("upstreams") if isinstance(dns.get("upstreams"), list) and dns.get("upstreams") else []
if not entries and dns.get("upstream_addr"):
    entries = [dns.get("upstream_addr")]

seen = set()
print(listen)
for entry in entries:
    entry = str(entry).strip()
    if entry and entry not in seen and valid(entry):
        seen.add(entry)
        print(entry)
PY
)

LISTEN="${CONFIG_LINES[0]:-127.0.0.1:5533}"
UPSTREAMS=("${CONFIG_LINES[@]:1}")

if [[ ${#UPSTREAMS[@]} -eq 0 ]]; then
  echo "FAIL: no valid configured upstreams" >&2
  exit 2
fi

echo "== current proxy answer test =="
bash "$SCRIPT_DIR/dns-proxy-test.sh" "$DOMAIN" A "$LISTEN"

GOOD_UPSTREAM=""
echo
echo "== selecting reachable upstream for temporary failover test =="
for upstream in "${UPSTREAMS[@]}"; do
  if bash "$SCRIPT_DIR/dns-upstream-test.sh" "$upstream" "$DOMAIN"; then
    GOOD_UPSTREAM="$upstream"
    break
  fi
done

if [[ -z "$GOOD_UPSTREAM" ]]; then
  echo "temporary failover test: SKIP no directly reachable configured upstream"
  exit 0
fi

if [[ -x "$REPO_DIR/target/debug/eve-net" ]]; then
  EVE_NET_CMD=("$REPO_DIR/target/debug/eve-net")
elif [[ -x /usr/local/bin/eve-net ]]; then
  EVE_NET_CMD=(/usr/local/bin/eve-net)
else
  EVE_NET_CMD=(cargo run --)
fi

TMP_DIR="$(mktemp -d)"
PID=""
cleanup() {
  if [[ -n "${PID:-}" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

PORT=5534
while ss -H -ulpn "sport = :$PORT" 2>/dev/null | grep -q .; do
  PORT=$((PORT + 1))
done
TEMP_LISTEN="127.0.0.1:$PORT"
TEMP_CONFIG="$TMP_DIR/policy.failover.json"
BAD_UPSTREAM="203.0.113.1:53"

python3 - "$CONFIG" "$TEMP_CONFIG" "$TEMP_LISTEN" "$BAD_UPSTREAM" "$GOOD_UPSTREAM" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
listen = sys.argv[3]
bad = sys.argv[4]
good = sys.argv[5]

cfg = json.loads(src.read_text())
cfg.setdefault("dns_interception", {})
cfg["dns_interception"]["enabled"] = True
cfg["dns_interception"]["listen_addr"] = listen
cfg["dns_interception"]["upstream_addr"] = bad
cfg["dns_interception"]["upstreams"] = [bad, good]
cfg["dns_interception"]["timeout_ms"] = min(int(cfg["dns_interception"].get("timeout_ms", 1500)), 700)
cfg.setdefault("dns_cache", {})
cfg["dns_cache"]["dns_interception_enabled"] = True
cfg["dns_cache"]["unresolved_domain_mode"] = "hard_fail_closed_dns_required"
dst.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
PY

echo
echo "== temporary proxy failover test =="
echo "listen: $TEMP_LISTEN"
echo "bad_first: $BAD_UPSTREAM"
echo "good_second: $GOOD_UPSTREAM"

(
  cd "$REPO_DIR"
  "${EVE_NET_CMD[@]}" dns-proxy --config "$TEMP_CONFIG" --apply
) >"$TMP_DIR/proxy.log" 2>&1 &
PID="$!"

for _ in $(seq 1 30); do
  if ss -H -ulpn "sport = :$PORT" 2>/dev/null | grep -q .; then
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "temporary proxy failed to start" >&2
    sed -n '1,120p' "$TMP_DIR/proxy.log" >&2 || true
    exit 2
  fi
  sleep 0.2
done

bash "$SCRIPT_DIR/dns-proxy-test.sh" "$DOMAIN" A "$TEMP_LISTEN"
echo "temporary failover test: PASS"
