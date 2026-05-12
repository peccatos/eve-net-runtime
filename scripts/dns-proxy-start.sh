#!/usr/bin/env bash
set -euo pipefail
sudo systemctl start eve-net-dns-proxy.service
systemctl status eve-net-dns-proxy.service --no-pager -l
