#!/usr/bin/env bash
set -euo pipefail
CONFIG="${1:-/etc/eve-net/policy.json}"
DOMAIN="${2:-}"

if [[ -n "$DOMAIN" ]]; then
  /usr/local/bin/eve-net domain-resolve --config "$CONFIG" "$DOMAIN"
else
  /usr/local/bin/eve-net domain-resolve --config "$CONFIG"
fi
