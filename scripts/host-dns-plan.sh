#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
if [[ ! -f "$CONFIG" ]]; then
  echo "missing config: $CONFIG" >&2
  exit 1
fi

json_get() {
  local file="$1" expr="$2"
  python3 - "$file" "$expr" <<'PYJSON'
import json, sys
p, expr = sys.argv[1], sys.argv[2]
obj = json.load(open(p))
cur = obj
for part in expr.split('.'):
    if not part:
        continue
    if isinstance(cur, dict):
        cur = cur.get(part)
    else:
        cur = None
        break
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PYJSON
}

LISTEN="$(json_get "$CONFIG" dns_interception.listen_addr)"
UPSTREAM="$(json_get "$CONFIG" dns_interception.upstream_addr)"
ENABLED="$(json_get "$CONFIG" dns_interception.enabled)"

echo "== eve-net host DNS integration plan =="
echo "config: $CONFIG"
echo "dns_interception.enabled: ${ENABLED:-unset}"
echo "listen_addr: ${LISTEN:-unset}"
echo "upstream_addr: ${UPSTREAM:-unset}"

echo
if [[ "$LISTEN" != "127.0.0.1:53" ]]; then
  echo "BLOCKER: host DNS integration requires listen_addr=127.0.0.1:53"
  echo "fix: sudo bash scripts/enable-host-dns-config.sh $CONFIG auto"
else
  echo "listen_addr: OK for systemd-resolved runtime DNS and legacy host DNS methods"
fi

echo
bash scripts/host-dns-detect.sh || true

echo
cat <<'PLAN'
apply plan:
  1. snapshot current systemd-resolved runtime state under /var/lib/eve-net/host-dns-runtime-snapshots/<timestamp>.json
  2. require eve-net-dns-proxy.service active on 127.0.0.1:53
  3. prefer systemd-resolved runtime DNS on wlo1 and amn0 if present
  4. set per-link DNS=127.0.0.1, domain=~., and DefaultRoute=yes
  5. keep legacy NetworkManager/resolv.conf methods explicit
  6. restore the runtime snapshot on validation failure
  7. test DNS resolution through host resolver
rollback plan:
  - restore the latest runtime snapshot by default
  - run repair mode if the restored snapshot still leaves host DNS broken
  - legacy resolvectl revert is available only with --legacy-revert
PLAN
