#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
FALLBACK_UPSTREAM="111.88.96.50:53"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/host-dns-runtime-repair.sh /etc/eve-net/policy.json" >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "missing config: $CONFIG" >&2
  exit 1
fi

if ! command -v resolvectl >/dev/null 2>&1; then
  echo "missing command: resolvectl" >&2
  exit 1
fi

if [[ ! -d /sys/class/net/wlo1 ]]; then
  echo "missing required DNS link: wlo1" >&2
  exit 1
fi

python3 - "$CONFIG" "$FALLBACK_UPSTREAM" <<'PY'
import ipaddress
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
fallback_upstream = sys.argv[2]
cfg = json.loads(path.read_text())


def valid_socket_addr(value):
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


dns = cfg.setdefault("dns_interception", {})
dns["enabled"] = True
dns["listen_addr"] = "127.0.0.1:53"
if not valid_socket_addr(dns.get("upstream_addr")):
    dns["upstream_addr"] = fallback_upstream
upstreams = dns.get("upstreams")
if not isinstance(upstreams, list):
    upstreams = []
valid_upstreams = [item for item in upstreams if valid_socket_addr(item)]
if not valid_upstreams:
    valid_upstreams = [dns["upstream_addr"]]
dns["upstreams"] = list(dict.fromkeys(valid_upstreams))
dns["cache_answers"] = True
dns["deny_unresolved_policy_domains"] = True
dns["deny_aaaa_for_policy_domains"] = True
dns["auto_redirect_enabled"] = False

cache = cfg.setdefault("dns_cache", {})
cache["enabled"] = True
cache["dns_interception_enabled"] = True
cache["unresolved_domain_mode"] = "hard_fail_closed_dns_required"
cache["fail_closed_unresolved"] = True

path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print("repaired DNS proxy config")
print("dns_interception.enabled=true")
print("dns_interception.listen_addr=127.0.0.1:53")
print(f"dns_interception.upstream_addr={dns.get('upstream_addr')}")
print(f"dns_interception.upstreams={dns.get('upstreams')}")
print("dns_cache.dns_interception_enabled=true")
print("dns_cache.unresolved_domain_mode=hard_fail_closed_dns_required")
PY

systemctl restart eve-net-dns-proxy.service
bash scripts/dns-proxy-test.sh example.com A 127.0.0.1:53

links=(wlo1)
if [[ -d /sys/class/net/amn0 ]]; then
  links+=(amn0)
fi

for link in "${links[@]}"; do
  resolvectl dns "$link" 127.0.0.1
  resolvectl domain "$link" '~.'
  resolvectl default-route "$link" yes
done

resolvectl flush-caches || true

for domain in example.com openai.com; do
  resolvectl query -t A "$domain"
  getent ahostsv4 "$domain"
done

echo "host DNS runtime repair: PASS"
