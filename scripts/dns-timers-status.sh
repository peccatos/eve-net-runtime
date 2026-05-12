#!/usr/bin/env bash
set -euo pipefail
systemctl status eve-net-dns-refresh.timer eve-net-dns-prune.timer --no-pager -l || true
echo
systemctl list-timers 'eve-net-dns-*' --no-pager || true
