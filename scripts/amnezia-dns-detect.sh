#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-human}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/amnezia-dns-detect.sh" >&2
  exit 1
fi

TMP_RULESET="$(mktemp)"
trap 'rm -f "$TMP_RULESET"' EXIT

if ! nft list ruleset >"$TMP_RULESET" 2>/dev/null; then
  echo "failed to read nft ruleset" >&2
  exit 2
fi

python3 - "$TMP_RULESET" "$MODE" <<'PY'
import re
import socket
import struct
import random
import sys
from pathlib import Path

ruleset_path = Path(sys.argv[1])
mode = sys.argv[2]
text = ruleset_path.read_text(errors="replace")

candidates = {}
current_chain = ""

for raw in text.splitlines():
    line = raw.strip()
    m_chain = re.match(r"chain\s+([^\s{]+)\s*\{", line)
    if m_chain:
        current_chain = m_chain.group(1)
        continue

    if "dport 53" not in line or "accept" not in line or "ip daddr" not in line:
        continue

    m_ip = re.search(r"\bip\s+daddr\s+([0-9]{1,3}(?:\.[0-9]{1,3}){3})\b", line)
    if not m_ip:
        continue

    ip = m_ip.group(1)
    score = 0
    reasons = []

    if "amnvpn" in current_chain:
        score += 20
        reasons.append(f"chain={current_chain}")
    if "allowDNS" in current_chain or "allowdns" in current_chain.lower():
        score += 20
        reasons.append("allowDNS")
    if 'oifname "amn' in line:
        score += 10
        reasons.append("oifname=amn*")
    if 'oifname "tun' in line:
        score += 8
        reasons.append("oifname=tun*")
    if "udp dport 53" in line:
        score += 3
        reasons.append("udp53")
    if "tcp dport 53" in line:
        score += 1
        reasons.append("tcp53")

    prev = candidates.get(ip)
    entry = {
        "ip": ip,
        "score": score,
        "chain": current_chain,
        "line": line,
        "reasons": reasons,
    }
    if prev is None or entry["score"] > prev["score"]:
        candidates[ip] = entry

items = sorted(candidates.values(), key=lambda x: (-x["score"], x["ip"]))

# Optional reachability probe: do not make detection depend on it, but prefer reachable DNS.
def probe(ip: str, domain: str = "example.com", timeout: float = 1.2):
    qid = random.randrange(0, 65536)
    header = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    qname = b"".join(bytes([len(label)]) + label.encode() for label in domain.split(".")) + b"\x00"
    query = header + qname + struct.pack("!HH", 1, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(query, (ip, 53))
        data, _ = sock.recvfrom(512)
        if len(data) < 12:
            return False, "short-response"
        rcode = data[3] & 0x0F
        ancount = struct.unpack("!H", data[6:8])[0]
        return rcode == 0, f"rcode={rcode},answers={ancount}"
    except Exception as e:
        return False, repr(e)
    finally:
        sock.close()

for item in items:
    ok, detail = probe(item["ip"])
    item["probe_ok"] = ok
    item["probe_detail"] = detail
    if ok:
        item["score"] += 100

items = sorted(items, key=lambda x: (-x["score"], x["ip"]))
usable_items = [item for item in items if item["probe_ok"]]
selected_items = usable_items if usable_items else items

if mode == "--selected-only":
    if not selected_items:
        raise SystemExit(2)
    print(selected_items[0]["ip"] + ":53")
    raise SystemExit(0)

if mode == "--list-only":
    if not selected_items:
        raise SystemExit(2)
    for item in selected_items:
        print(item["ip"] + ":53")
    raise SystemExit(0)

print("eve-net amnezia dns detect")
if not items:
    print("dns_candidates: none")
    print("hint: no Amnezia DNS allow rules found in nft ruleset")
    raise SystemExit(2)

print("dns_candidates:")
for item in items:
    print(f"  - {item['ip']}:53")
    print(f"    score: {item['score']}")
    print(f"    chain: {item['chain']}")
    print(f"    probe: {'OK' if item['probe_ok'] else 'FAIL'} ({item['probe_detail']})")
    if item["reasons"]:
        print(f"    reasons: {', '.join(item['reasons'])}")
    print(f"    rule: {item['line']}")
print(f"selected: {selected_items[0]['ip']}:53")
if usable_items:
    print("usable:")
    for item in usable_items:
        print(f"  - {item['ip']}:53")
PY
