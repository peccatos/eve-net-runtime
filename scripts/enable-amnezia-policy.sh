#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
IFACE="${2:-amn0}"
DOMAIN="${3:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/enable-amnezia-policy.sh /etc/eve-net/policy.json amn0 [domain]" >&2
  exit 1
fi

python3 - "$CONFIG" "$IFACE" "$DOMAIN" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
iface = sys.argv[2]
domain = sys.argv[3].strip()

cfg = json.loads(path.read_text())
cfg.setdefault("runtime", {})["dry_run"] = False

egresses = cfg.setdefault("egress_interfaces", [])
for e in egresses:
    if e.get("name") in ("wg0", "wg1"):
        e["enabled"] = False

amn = {
    "enabled": True,
    "name": iface,
    "kind": "tunnel",
    "table": 250,
    "fwmark": 250,
    "rule_priority": 1010,
    "healthcheck": {"enabled": False, "target_ip": "1.1.1.1", "timeout_ms": 1500},
    "gateway": None,
    "source_ip": None,
}
for idx, e in enumerate(egresses):
    if e.get("name") == iface:
        egresses[idx] = amn
        break
else:
    egresses.append(amn)

policies = cfg.setdefault("policies", [])
for pol in policies:
    if pol.get("id") in ("cloudflare-dns-through-wg0-template", "google-dns-through-wg1-template"):
        pol["enabled"] = False

# Split test: Cloudflare via Amnezia, Google via direct Wi-Fi.
policies = [p for p in policies if p.get("id") not in ("cloudflare-dns-through-amnezia", "domain-through-amnezia")]
for pol in policies:
    if pol.get("id") == "cloudflare-dns-through-direct-wifi":
        pol["enabled"] = False
    if pol.get("id") == "google-dns-through-direct-wifi":
        pol["enabled"] = True
        pol["action"] = {"egress": "wlo1"}

policies.append({
    "id": "cloudflare-dns-through-amnezia",
    "enabled": True,
    "match": {"dest_ip": "1.1.1.1"},
    "action": {"egress": iface},
})

if domain:
    policies.append({
        "id": "domain-through-amnezia",
        "enabled": True,
        "match": {"domain": domain},
        "action": {"egress": iface},
    })

cfg["policies"] = policies
path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"enabled {iface} tunnel egress in {path}")
if domain:
    print(f"enabled domain policy: {domain} -> {iface}")
PY
