#!/usr/bin/env bash
    set -euo pipefail

    CONFIG="${1:?usage: bash scripts/disable-wg-policy.sh /etc/eve-net/policy.json wg0|wg1}"
    IFACE="${2:?usage: bash scripts/disable-wg-policy.sh /etc/eve-net/policy.json wg0|wg1}"

    if [[ ! "$IFACE" =~ ^wg[0-9]+$ ]]; then
      echo "Refusing suspicious interface name: $IFACE" >&2
      exit 1
    fi

    python3 - "$CONFIG" "$IFACE" <<'INNERPY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
iface = sys.argv[2]
cfg = json.loads(path.read_text())

for egress in cfg.get("egress_interfaces", []):
    if egress.get("name") == iface:
        egress["enabled"] = False

for policy in cfg.get("policies", []):
    if policy.get("action", {}).get("egress") == iface:
        policy["enabled"] = False

path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"disabled egress and policies for {iface} in {path}")
INNERPY
