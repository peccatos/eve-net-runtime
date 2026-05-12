#!/usr/bin/env bash
set -euo pipefail
UPSTREAM="${1:-111.88.96.50:53}"
DOMAIN="${2:-example.com}"
python3 - "$UPSTREAM" "$DOMAIN" <<'PY'
import random, socket, struct, sys
upstream, domain = sys.argv[1], sys.argv[2]
if ':' not in upstream:
    upstream = upstream + ':53'
host, port_s = upstream.rsplit(':', 1)
port = int(port_s)
qid = random.randrange(0, 65536)
header = struct.pack('!HHHHHH', qid, 0x0100, 1, 0, 0, 0)
qname = b''.join(bytes([len(label)]) + label.encode() for label in domain.rstrip('.').split('.')) + b'\x00'
query = header + qname + struct.pack('!HH', 1, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3.0)
try:
    sock.sendto(query, (host, port))
    data, addr = sock.recvfrom(4096)
    if len(data) < 12:
        print(f'FAIL: short response from {addr}, bytes={len(data)}')
        raise SystemExit(3)
    rcode = data[3] & 0x0f
    ancount = struct.unpack('!H', data[6:8])[0]
    print(f'OK: upstream={host}:{port} domain={domain} rcode={rcode} answers={ancount} bytes={len(data)}')
except Exception as e:
    print(f'FAIL: upstream={host}:{port} domain={domain} error={e!r}')
    raise SystemExit(2)
PY
