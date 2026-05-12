#!/usr/bin/env bash
set -euo pipefail
cat <<'MSG'
DNS interception preparation for phase 0.10+

v0.10 status:
  - local UDP DNS proxy exists: 127.0.0.1:5533
  - systemd unit exists: eve-net-dns-proxy.service
  - host-wide DNS redirect is NOT installed automatically
  - /etc/resolv.conf and NetworkManager are NOT mutated

Safe test flow:
  sudo bash scripts/enable-dns-interception-config.sh /etc/eve-net/policy.json
  sudo systemctl start eve-net-dns-proxy.service
  bash scripts/dns-proxy-test.sh example.com
  journalctl -u eve-net-dns-proxy.service -n 80 --no-pager -l

Future hard interception pieces:
  1. decide whether to use NetworkManager DNS override or nft redirect
  2. avoid loops: proxy must forward upstream without being redirected into itself
  3. decide DoH/DoT policy; browsers may bypass system DNS
  4. add explicit rollback script before touching host-wide DNS
MSG
