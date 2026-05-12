#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
DOMAIN="${2:-example.com}"

if [[ ! -f "$CONFIG" ]]; then
  echo "missing config: $CONFIG" >&2
  exit 1
fi

python3 - "$CONFIG" "$DOMAIN" <<'PY'
import ipaddress
import json
import random
import socket
import struct
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
domain = sys.argv[2].strip().rstrip(".") or "example.com"
cfg = json.loads(config_path.read_text())
dns = cfg.get("dns_interception", {})


def parse_socket_addr(value):
    if not isinstance(value, str):
        raise ValueError("not a string")
    value = value.strip()
    if not value:
        raise ValueError("empty")
    if value.startswith("["):
        host, port_text = value.rsplit("]:", 1)
        host = host[1:]
    else:
        host, port_text = value.rsplit(":", 1)
        if ":" in host:
            raise ValueError("IPv6 addresses must use [addr]:port")
    ipaddress.ip_address(host)
    port = int(port_text)
    if not (1 <= port <= 65535):
        raise ValueError("invalid port")
    return host, port, f"[{host}]:{port}" if ":" in host else f"{host}:{port}"


entries = dns.get("upstreams") if isinstance(dns.get("upstreams"), list) and dns.get("upstreams") else []
if not entries:
    upstream_addr = dns.get("upstream_addr", "")
    entries = [upstream_addr] if upstream_addr else []

valid = []
seen = set()
for entry in entries:
    try:
        host, port, normalized = parse_socket_addr(entry)
    except Exception as exc:
        print(f"upstream={entry!r} status=FAIL reason=malformed ({exc})")
        continue
    if normalized in seen:
        continue
    seen.add(normalized)
    valid.append((host, port, normalized))

if not valid:
    print("summary: FAIL no valid configured DNS upstreams")
    raise SystemExit(2)


def build_query(domain):
    qid = random.randrange(0, 65536)
    header = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    qname = b"".join(bytes([len(label)]) + label.encode() for label in domain.split(".")) + b"\x00"
    return header + qname + struct.pack("!HH", 1, 1)


query = build_query(domain)
passed = 0
for host, port, normalized in valid:
    sock = None
    try:
        sock = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(3.0)
        sock.sendto(query, (host, port))
        data, _ = sock.recvfrom(4096)
        if len(data) < 12:
            print(f"upstream={normalized} domain={domain} status=FAIL reason=short-response bytes={len(data)}")
            continue
        rcode = data[3] & 0x0F
        answers = struct.unpack("!H", data[6:8])[0]
        if rcode == 0:
            passed += 1
            print(f"upstream={normalized} domain={domain} status=PASS rcode={rcode} answers={answers} bytes={len(data)}")
        else:
            print(f"upstream={normalized} domain={domain} status=FAIL rcode={rcode} answers={answers} bytes={len(data)}")
    except Exception as exc:
        print(f"upstream={normalized} domain={domain} status=FAIL reason={exc!r}")
    finally:
        if sock is not None:
            sock.close()

print(f"summary: {'PASS' if passed else 'FAIL'} passed={passed} total={len(valid)}")
raise SystemExit(0 if passed else 2)
PY
