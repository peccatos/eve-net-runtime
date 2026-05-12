#!/usr/bin/env bash
set -euo pipefail
CONFIG="${1:-/etc/eve-net/policy.json}"

UPSTREAM="$(python3 - "$CONFIG" <<'PY'
import json, sys
from pathlib import Path
cfg=json.loads(Path(sys.argv[1]).read_text())
print(cfg.get('dns_interception', {}).get('upstream_addr', ''))
PY
)"
HOST="${UPSTREAM%:*}"

if [[ -z "$UPSTREAM" ]]; then
  echo "dns upstream: not configured"
  exit 1
fi

echo "dns upstream: $UPSTREAM"

TMP_RULESET="$(mktemp)"
trap 'rm -f "$TMP_RULESET"' EXIT
if sudo nft list ruleset >"$TMP_RULESET" 2>/dev/null; then
  python3 - "$TMP_RULESET" "$HOST" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors='replace')
host = sys.argv[2]
current = ''
block_dns = False
allow_dns_for_host = False
allow_lines = []
block_lines = []
for raw in text.splitlines():
    line = raw.strip()
    m = re.match(r'chain\s+([^\s{]+)\s*\{', line)
    if m:
        current = m.group(1)
        continue
    if 'amnvpn' in current and 'blockDNS' in current and 'dport 53' in line and ('reject' in line or 'drop' in line):
        block_dns = True
        block_lines.append(f'{current}: {line}')
    if 'amnvpn' in current and 'allowDNS' in current and 'dport 53' in line and 'accept' in line:
        if f'ip daddr {host}' in line:
            allow_dns_for_host = True
            allow_lines.append(f'{current}: {line}')
print(f"amnezia blockDNS: {'detected' if block_dns else 'not detected'}")
if block_dns:
    print('amnezia blockDNS sample:')
    for x in block_lines[:4]:
        print(f'  - {x}')
print(f"upstream explicitly allowed by Amnezia DNS rules: {'yes' if allow_dns_for_host else 'no'}")
if allow_lines:
    for x in allow_lines[:4]:
        print(f'  - {x}')
PY
else
  echo "amnezia blockDNS: unknown (cannot read nft ruleset)"
fi

if [[ "$HOST" =~ ^(1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9|149\.112\.112\.112)$ ]]; then
  echo "warning: upstream is a public DNS server; Amnezia may reject public DNS/53 with EPERM"
  echo "hint: run: sudo bash scripts/amnezia-dns-detect.sh"
else
  echo "upstream class: custom/provider DNS"
fi
