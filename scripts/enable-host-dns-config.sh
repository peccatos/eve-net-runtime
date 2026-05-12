#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
UPSTREAM="${2:-keep}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAMS=()

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/enable-host-dns-config.sh /etc/eve-net/policy.json [auto|keep|IP:53]" >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "missing config: $CONFIG" >&2
  exit 1
fi

resolve_auto_upstreams() {
  if [[ -x "$SCRIPT_DIR/amnezia-dns-detect.sh" ]]; then
    bash "$SCRIPT_DIR/amnezia-dns-detect.sh" --list-only 2>/dev/null || true
  fi
}

if [[ "$UPSTREAM" == "auto" ]]; then
  mapfile -t UPSTREAMS < <(resolve_auto_upstreams)
  if [[ ${#UPSTREAMS[@]} -eq 0 ]]; then
    UPSTREAMS=("111.88.96.50:53" "111.88.96.51:53")
  fi
  UPSTREAM="${UPSTREAMS[0]}"
elif [[ "$UPSTREAM" != "keep" ]]; then
  UPSTREAMS=("$UPSTREAM")
fi

python3 - "$CONFIG" "$UPSTREAM" "${UPSTREAMS[@]}" <<'PYCFG'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
upstream = sys.argv[2]
upstreams = sys.argv[3:]
cfg = json.loads(p.read_text())

dns = cfg.setdefault("dns_interception", {})
dns["enabled"] = True
dns["listen_addr"] = "127.0.0.1:53"
if upstream != "keep":
    dns["upstream_addr"] = upstream
    dns["upstreams"] = list(dict.fromkeys(upstreams or [upstream]))
elif dns.get("upstream_addr") and not dns.get("upstreams"):
    dns["upstreams"] = [dns["upstream_addr"]]
dns["cache_answers"] = True
dns["deny_unresolved_policy_domains"] = True
dns["deny_aaaa_for_policy_domains"] = True
dns["auto_redirect_enabled"] = False

cache = cfg.setdefault("dns_cache", {})
cache["enabled"] = True
cache["dns_interception_enabled"] = True
cache["unresolved_domain_mode"] = "hard_fail_closed_dns_required"
cache["fail_closed_unresolved"] = True

p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print("enabled host DNS integration config")
print("dns_interception.listen_addr=127.0.0.1:53")
print(f"dns_interception.upstream_addr={dns.get('upstream_addr')}")
print(f"dns_interception.upstreams={dns.get('upstreams')}")
print("note: this changes eve-net config only; it does not modify NetworkManager or /etc/resolv.conf")
PYCFG
