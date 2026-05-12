#!/usr/bin/env bash
set -euo pipefail
journalctl -u eve-net-dns-proxy.service -n 120 --no-pager -l
