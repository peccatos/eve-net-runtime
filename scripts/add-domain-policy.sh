#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-}"
DOMAIN="${2:-}"
EGRESS="${3:-}"
POLICY_ID="${4:-}"

if [[ -z "$CONFIG" || -z "$DOMAIN" || -z "$EGRESS" ]]; then
  echo "Usage: sudo bash scripts/add-domain-policy.sh /etc/eve-net/policy.json example.com amn0 [policy-id]" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root because /etc/eve-net/policy.json is root-owned." >&2
  exit 1
fi

python3 - "$CONFIG" "$DOMAIN" "$EGRESS" "$POLICY_ID" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
domain = sys.argv[2].strip().lower().rstrip('.')
egress = sys.argv[3].strip()
policy_id = sys.argv[4].strip()

if not re.fullmatch(r"[a-z0-9.-]+", domain) or "/" in domain or ":" in domain:
    raise SystemExit(f"invalid bare domain: {domain}")
if not policy_id:
    safe = re.sub(r"[^a-z0-9]+", "-", domain).strip('-')
    policy_id = f"domain-{safe}-through-{egress}"

cfg = json.loads(path.read_text())
if not any(e.get("name") == egress for e in cfg.get("egress_interfaces", [])):
    raise SystemExit(f"unknown egress: {egress}")

policies = cfg.setdefault("policies", [])
for existing in policies:
    if existing.get("id") == policy_id:
        continue
    match = existing.get("match") or {}
    existing_domain = str(match.get("domain", "")).strip().lower().rstrip('.')
    if existing.get("enabled") is True and existing_domain == domain:
        raise SystemExit(
            f"duplicate enabled domain policy for {domain}: {existing.get('id')}. "
            "Disable/remove it first or pass the same policy-id to update."
        )
policies[:] = [p for p in policies if p.get("id") != policy_id]
policies.append({
    "id": policy_id,
    "enabled": True,
    "match": {"domain": domain},
    "action": {"egress": egress},
})

path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"added domain policy: {policy_id}: {domain} -> {egress}")
PY
