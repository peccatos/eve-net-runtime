#!/usr/bin/env bash
set -euo pipefail
PORT="${1:-5533}"
echo "== UDP listeners for port ${PORT} =="
if ss -H -ulpn "sport = :${PORT}" 2>/dev/null | grep .; then
  echo
  echo "port ${PORT} is busy"
  exit 1
else
  echo "port ${PORT} is free"
fi

echo
if command -v ss >/dev/null 2>&1; then
  echo "== common DNS/mDNS listeners =="
  ss -H -ulpn 2>/dev/null | grep -E ':(53|5353|5533)\b' || true
fi
