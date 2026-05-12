#!/usr/bin/env bash
set -euo pipefail
sudo systemctl stop eve-net.service
systemctl status eve-net.service --no-pager || true
