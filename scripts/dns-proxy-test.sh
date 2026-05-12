#!/usr/bin/env bash
set -euo pipefail
DOMAIN="${1:-example.com}"
QTYPE="${2:-A}"
SERVER_PORT="${3:-127.0.0.1:5533}"
SERVER="${SERVER_PORT%:*}"
PORT="${SERVER_PORT##*:}"

python3 - "$DOMAIN" "$QTYPE" "$SERVER" "$PORT" <<'PY'
import socket, struct, random, sys

domain = sys.argv[1].strip().rstrip('.')
qtype_name = sys.argv[2].strip().upper()
server = sys.argv[3]
port = int(sys.argv[4])
qtype_map = {"A": 1, "AAAA": 28}
if qtype_name not in qtype_map:
    print(f"dns_proxy_test: unsupported qtype={qtype_name}; supported: A, AAAA")
    raise SystemExit(64)
qtype = qtype_map[qtype_name]

def build_query(domain, qtype):
    tid = random.randint(0, 65535)
    q = struct.pack('!HHHHHH', tid, 0x0100, 1, 0, 0, 0)
    for part in domain.split('.'):
        q += bytes([len(part)]) + part.encode()
    q += b'\x00' + struct.pack('!HH', qtype, 1)
    return q

query = build_query(domain, qtype)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3.0)
try:
    sock.sendto(query, (server, port))
    data, _ = sock.recvfrom(4096)
except socket.timeout:
    print(f'dns_proxy_test: TIMEOUT domain={domain} qtype={qtype_name} server={server}:{port}')
    print('hint: start the proxy first: sudo systemctl start eve-net-dns-proxy.service')
    print('hint: then inspect logs: journalctl -u eve-net-dns-proxy.service -n 80 --no-pager -l')
    raise SystemExit(2)
finally:
    sock.close()

if len(data) < 12:
    print(f'dns_proxy_test: invalid short response length={len(data)}')
    raise SystemExit(3)

rcode = data[3] & 0x0f
ancount = struct.unpack('!H', data[6:8])[0]
print(f'dns_proxy_test: domain={domain} qtype={qtype_name} server={server}:{port} rcode={rcode} answers={ancount}')
if rcode == 5:
    print('hint: rcode=5 REFUSED. This is expected for denied policy-domain AAAA/unresolved tests, or indicates upstream DNS refusal.')
elif rcode == 2:
    print('hint: rcode=2 SERVFAIL. Inspect journalctl -u eve-net-dns-proxy.service -n 80 --no-pager -l')

# Skip question.
pos = 12
while pos < len(data) and data[pos] != 0:
    pos += 1 + data[pos]
pos += 1 + 4

answers = []
for _ in range(ancount):
    if pos >= len(data):
        break
    if data[pos] & 0xc0 == 0xc0:
        pos += 2
    else:
        while pos < len(data) and data[pos] != 0:
            pos += 1 + data[pos]
        pos += 1
    if pos + 10 > len(data):
        break
    typ, cls, ttl, rdlen = struct.unpack('!HHIH', data[pos:pos+10])
    pos += 10
    rdata = data[pos:pos+rdlen]
    pos += rdlen
    if typ == 1 and cls == 1 and rdlen == 4:
        answers.append('A ' + '.'.join(map(str, rdata)))
    elif typ == 28 and cls == 1 and rdlen == 16:
        parts = [rdata[i:i+2].hex() for i in range(0, 16, 2)]
        answers.append('AAAA ' + ':'.join(parts))

if answers:
    print('answers:')
    for ans in answers:
        print(f'  - {ans}')
PY
