#!/usr/bin/env bash
set -euo pipefail
sudo systemctl start eve-net.service
systemctl status eve-net.service --no-pager
