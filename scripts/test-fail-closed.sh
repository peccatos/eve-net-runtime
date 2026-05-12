#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
BIN="${EVE_NET_BIN:-/usr/local/bin/eve-net}"
TMP_DIR="$(mktemp -d)"
TMP_CONFIG="$TMP_DIR/policy.json"
TMP_CACHE="$TMP_DIR/dns-cache.json"
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$CONFIG" "$TMP_CONFIG"
python3 - "$TMP_CONFIG" "$TMP_CACHE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
cache_path = sys.argv[2]
cfg = json.loads(path.read_text())
cfg.setdefault("runtime", {})["dry_run"] = True
cfg.setdefault("dns_cache", {})["enabled"] = True
cfg["dns_cache"]["path"] = cache_path
cfg["dns_cache"]["ttl_sec"] = 60
cfg["dns_cache"]["stale_grace_sec"] = 60
cfg["dns_cache"]["fail_closed_unresolved"] = True
cfg["dns_cache"]["unresolved_domain_mode"] = "soft_fail_closed_l3"
cfg["dns_cache"]["dns_interception_enabled"] = False
policies = cfg.setdefault("policies", [])
policies[:] = [p for p in policies if p.get("id") != "fail-closed-unresolved-test"]
policies.append({
    "id": "fail-closed-unresolved-test",
    "enabled": True,
    "match": {"domain": "nonexistent-eve-net-test.invalid"},
    "action": {"egress": "wlo1"},
})
path.write_text(json.dumps(cfg, indent=2) + "\n")
PY

echo "== validate temp fail-closed config =="
"$BIN" validate --config "$TMP_CONFIG"
echo

echo "== dns-refresh temp fail-closed config =="
"$BIN" dns-refresh --config "$TMP_CONFIG"
echo

echo "== dry reconcile temp fail-closed config =="
"$BIN" reconcile --config "$TMP_CONFIG" --once

echo
echo "PASS if the unresolved domain policy produced no nft rule and explicit soft-fail-closed warnings. No host networking was mutated."
