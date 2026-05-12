#!/usr/bin/env bash
set -euo pipefail
CONFIG="${1:-/etc/eve-net/policy.json}"
UPSTREAM="${2:-auto}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAMS=()

if [[ "$UPSTREAM" == "auto" ]]; then
  DETECTED=()
  if [[ ${EUID:-$(id -u)} -eq 0 ]] && command -v nft >/dev/null 2>&1; then
    if [[ -x "$SCRIPT_DIR/amnezia-dns-detect.sh" ]]; then
      mapfile -t DETECTED < <(bash "$SCRIPT_DIR/amnezia-dns-detect.sh" --list-only 2>/dev/null || true)
    fi
  fi
  if [[ ${#DETECTED[@]} -gt 0 ]]; then
    UPSTREAM="${DETECTED[0]}"
    UPSTREAMS=("${DETECTED[@]}")
    AUTO_NOTE="auto-detected Amnezia-allowed DNS upstreams"
  else
    UPSTREAM="111.88.96.50:53"
    UPSTREAMS=("111.88.96.50:53" "111.88.96.51:53")
    AUTO_NOTE="auto-detect failed; fell back to Amnezia DNS defaults"
  fi
else
  UPSTREAMS=("$UPSTREAM")
  AUTO_NOTE="manual upstream"
fi

python3 - "$CONFIG" "$UPSTREAM" "${UPSTREAMS[@]}" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
upstream = sys.argv[2]
upstreams = sys.argv[3:]
cfg = json.loads(p.read_text())
cfg.setdefault("dns_cache", {})
cfg["dns_cache"]["dns_interception_enabled"] = True
cfg["dns_cache"]["unresolved_domain_mode"] = "hard_fail_closed_dns_required"
cfg["dns_cache"]["fail_closed_unresolved"] = True
cfg.setdefault("dns_interception", {})
cfg["dns_interception"]["listen_addr"] = "127.0.0.1:5533"
cfg["dns_interception"]["upstream_addr"] = upstream
cfg["dns_interception"]["upstreams"] = list(dict.fromkeys(upstreams or [upstream]))
cfg["dns_interception"].setdefault("timeout_ms", 1500)
cfg["dns_interception"]["enabled"] = True
cfg["dns_interception"].setdefault("cache_answers", True)
cfg["dns_interception"].setdefault("deny_unresolved_policy_domains", True)
cfg["dns_interception"].setdefault("deny_aaaa_for_policy_domains", True)
cfg["dns_interception"].setdefault("audit_log_queries", True)
cfg["dns_interception"]["auto_redirect_enabled"] = False
p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"enabled local DNS interception config in {p}")
print("listen_addr set to 127.0.0.1:5533 to avoid the mDNS 5353 port")
print(f"upstream_addr set to {upstream}")
print("upstreams set to:")
for item in cfg["dns_interception"]["upstreams"]:
    print(f"  - {item}")
PY

echo "selection: $AUTO_NOTE"
echo "note: Amnezia often blocks public DNS/53; auto mode prefers DNS allowed by Amnezia nft rules."
echo "note: this does not rewrite /etc/resolv.conf or NetworkManager. Start eve-net-dns-proxy.service and test explicitly."
