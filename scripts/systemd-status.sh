#!/usr/bin/env bash
set -euo pipefail
systemctl status eve-net.service --no-pager || true
echo
sudo /usr/local/bin/eve-net status --config /etc/eve-net/policy.json || true
