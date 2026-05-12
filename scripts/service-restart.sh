#!/usr/bin/env bash
set -euo pipefail
sudo systemctl restart eve-net.service
systemctl status eve-net.service --no-pager
