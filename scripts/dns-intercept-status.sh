#!/usr/bin/env bash
set -euo pipefail
CONFIG="${1:-/etc/eve-net/policy.json}"
exec /usr/local/bin/eve-net dns-intercept-status --config "$CONFIG"
