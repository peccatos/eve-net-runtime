#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
BIN="${EVE_NET_BIN:-/usr/local/bin/eve-net}"

echo "== eve-net DNS fail-closed semantics =="
echo "config: $CONFIG"
echo
"$BIN" status --config "$CONFIG" | sed -n '/^dns_cache:/,/^underlay:/p' | sed '/^underlay:/d'
echo
cat <<'TXT'
Meaning:
  soft_fail_closed_l3:
    - unresolved domain -> eve-net creates no nft route rule
    - already-known cached IPs may still be controlled
    - unknown future DNS answers cannot be blocked at L3 because there is no IP to match

  allow_stale:
    - unresolved domain -> stale cached IPs may be used during stale_grace_sec
    - useful for continuity, weaker for strict policy

  hard_fail_closed_dns_required:
    - requires a DNS interception / DNS proxy / DNS deny layer
    - eve-net v0.10 includes a local DNS proxy, but does not enable host-wide DNS redirect automatically
TXT
