#!/usr/bin/env bash
set -euo pipefail
CONFIG="${1:-/etc/eve-net/policy.json}"
sudo /usr/local/bin/eve-net dns-cache --config "$CONFIG"
