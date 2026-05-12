#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

read_json_field() {
  local expr="$1" default="$2"
  python3 - "$CONFIG" "$expr" "$default" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expr = sys.argv[2]
default = sys.argv[3]
try:
    cur = json.loads(path.read_text())
    for part in expr.split("."):
        cur = cur.get(part) if isinstance(cur, dict) else None
    print(default if cur in (None, "") else cur)
except Exception:
    print(default)
PY
}

echo "== eve-net host DNS status =="
if [[ -f "$CONFIG" ]]; then
  if [[ -x "$REPO_DIR/target/debug/eve-net" ]]; then
    "$REPO_DIR/target/debug/eve-net" dns-intercept-status --config "$CONFIG" 2>/dev/null || true
  elif [[ -x /usr/local/bin/eve-net ]]; then
    /usr/local/bin/eve-net dns-intercept-status --config "$CONFIG" 2>/dev/null || true
  else
    cargo run -- dns-intercept-status --config "$CONFIG" 2>/dev/null || true
  fi
fi

LISTEN="$(read_json_field dns_interception.listen_addr 127.0.0.1:5533)"
LISTEN_PORT="${LISTEN##*:}"
SERVICE_ENABLED="unknown"
if command -v systemctl >/dev/null 2>&1; then
  SERVICE_ENABLED="$(systemctl is-enabled eve-net-dns-proxy.service 2>/dev/null || true)"
  [[ -z "$SERVICE_ENABLED" ]] && SERVICE_ENABLED="unknown"
fi

PROXY_READY="no"
if command -v ss >/dev/null 2>&1 && ss -H -ulpn "sport = :$LISTEN_PORT" 2>/dev/null | grep -q .; then
  if bash "$SCRIPT_DIR/dns-proxy-test.sh" example.com A "$LISTEN" >/tmp/eve-net-host-dns-proxy-test.$$ 2>/dev/null; then
    PROXY_READY="yes"
  fi
fi
rm -f /tmp/eve-net-host-dns-proxy-test.$$

RESOLV_CONF_TEXT="$(sed -n '1,80p' /etc/resolv.conf 2>/dev/null || true)"
RESOLVECTL_DNS_TEXT="$(resolvectl dns 2>/dev/null || true)"

HOST_DNS_BOUND_TO_PROXY="no"
if printf '%s\n' "$RESOLV_CONF_TEXT" | grep -Eq '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.1([[:space:]]|$)'; then
  HOST_DNS_BOUND_TO_PROXY="yes"
elif printf '%s\n' "$RESOLVECTL_DNS_TEXT" | grep -Eq '(^|[[:space:]])127\.0\.0\.1([[:space:]]|$)'; then
  HOST_DNS_BOUND_TO_PROXY="yes"
fi

HOST_DNS_SAFE_FALLBACK_PRESENT="$(
  RESOLV_CONF_TEXT="$RESOLV_CONF_TEXT" RESOLVECTL_DNS_TEXT="$RESOLVECTL_DNS_TEXT" python3 - <<'PY'
import ipaddress
import os
import re

text = os.environ.get("RESOLV_CONF_TEXT", "") + "\n" + os.environ.get("RESOLVECTL_DNS_TEXT", "")
found = False
for token in re.findall(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])", text):
    try:
        ip = ipaddress.ip_address(token)
    except ValueError:
        continue
    if not ip.is_loopback and not ip.is_unspecified:
        found = True
        break
print("yes" if found else "no")
PY
)"

echo
echo "host_dns_diagnostics:"
echo "  proxy_ready: $PROXY_READY"
echo "  dns_proxy_service_enabled: $SERVICE_ENABLED"
echo "  host_dns_bound_to_proxy: $HOST_DNS_BOUND_TO_PROXY"
echo "  host_resolver_using_127_0_0_1: $HOST_DNS_BOUND_TO_PROXY"
echo "  host_dns_safe_fallback_present: $HOST_DNS_SAFE_FALLBACK_PRESENT"
if [[ "$LISTEN" == "127.0.0.1:53" && "$SERVICE_ENABLED" == "disabled" ]]; then
  echo "  warning: listen_addr is 127.0.0.1:53 but eve-net-dns-proxy.service is disabled"
fi
echo "  note: this status command is read-only; it does not mutate /etc/resolv.conf, NetworkManager, systemd, or resolvectl state"

echo
bash "$SCRIPT_DIR/host-dns-detect.sh" || true

echo
if command -v getent >/dev/null 2>&1; then
  echo "host resolver test:"
  if getent ahostsv4 example.com >/tmp/eve-net-host-dns-test.$$ 2>/dev/null; then
    echo "  PASS"
    sed 's/^/  /' /tmp/eve-net-host-dns-test.$$ | head -5
  else
    echo "  FAIL"
  fi
  rm -f /tmp/eve-net-host-dns-test.$$
fi
