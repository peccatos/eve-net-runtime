#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-config/policy.example.json}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
PREFLIGHT_CONFIG="$TMP_DIR/policy.preflight.json"
PREFLIGHT_CACHE="$TMP_DIR/dns-cache.json"

python3 - <<'PYCFG' "$CONFIG" "$PREFLIGHT_CONFIG" "$PREFLIGHT_CACHE"
import json, sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
cache = sys.argv[3]
cfg = json.loads(src.read_text())
cfg.setdefault("dns_cache", {})
cfg["dns_cache"]["path"] = cache
# Keep dry-run semantics for preflight, even if the source config is apply-enabled.
cfg.setdefault("runtime", {})
cfg["runtime"]["dry_run"] = True
dst.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"preflight_config: {dst}")
print(f"preflight_dns_cache: {cache}")
PYCFG

echo
echo "== commands =="
for bin in ip nft cargo systemctl wg wg-quick python3; do
  if command -v "$bin" >/dev/null 2>&1; then
    echo "ok: $bin -> $(command -v "$bin")"
  else
    echo "missing: $bin"
  fi
done

echo
echo "== cargo check =="
cargo check

echo
echo "== host network =="
ip route show default || true
ip -br link show | grep -E '^(wlo1|wlan0|wg0|wg1|amn0|tun0|tun1)\b' || true
wg show 2>/dev/null || true

echo
echo "== wireguard status =="
if command -v wg >/dev/null 2>&1; then wg --version || true; wg show || true; fi

echo
echo "== dry status (isolated temp DNS cache) =="
cargo run -- status --config "$PREFLIGHT_CONFIG" || true

echo
echo "== tunnel detect =="
cargo run -- tunnel-detect || true

echo
echo "== domain resolve =="
cargo run -- domain-resolve --config "$PREFLIGHT_CONFIG" || true

echo
echo "== dry reconcile =="
cargo run -- reconcile --config "$PREFLIGHT_CONFIG" --once || true

echo
echo "== dns cache (isolated temp DNS cache) =="
cargo run -- dns-cache --config "$PREFLIGHT_CONFIG" || true

echo
echo "== dns refresh dry-run (isolated temp DNS cache) =="
cargo run -- dns-refresh --config "$PREFLIGHT_CONFIG" || true

echo
echo "== validate (isolated temp DNS cache) =="
cargo run -- validate --config "$PREFLIGHT_CONFIG" || true

echo
echo "== dns intercept status =="
cargo run -- dns-intercept-status --config "$PREFLIGHT_CONFIG" || true

echo
echo "== production DNS cache readability hint =="
PROD_CACHE_PATH="$(python3 - <<'PYCACHE' "$CONFIG"
import json, sys
from pathlib import Path
try:
    cfg=json.loads(Path(sys.argv[1]).read_text())
    print(cfg.get("dns_cache", {}).get("path", "/var/lib/eve-net/dns-cache.json"))
except Exception:
    print("/var/lib/eve-net/dns-cache.json")
PYCACHE
)"
if [ -e "$PROD_CACHE_PATH" ] && [ ! -r "$PROD_CACHE_PATH" ]; then
  echo "note: production DNS cache exists but is not readable by current user: $PROD_CACHE_PATH"
  echo "note: this is normal; inspect it with: sudo /usr/local/bin/eve-net dns-cache --config /etc/eve-net/policy.json"
else
  echo "ok: production DNS cache path is absent or readable by current user: $PROD_CACHE_PATH"
fi
