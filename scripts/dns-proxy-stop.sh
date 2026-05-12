#!/usr/bin/env bash
set -euo pipefail
sudo systemctl stop eve-net-dns-proxy.service
systemctl status eve-net-dns-proxy.service --no-pager -l || true
