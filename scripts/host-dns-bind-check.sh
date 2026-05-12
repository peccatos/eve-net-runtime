#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-53}"
ADDR="${2:-127.0.0.1}"

echo "== eve-net host DNS bind check =="
echo "target: ${ADDR}:${PORT}"

echo
if command -v ss >/dev/null 2>&1; then
  echo "current UDP listeners on :${PORT}:"
  ss -ulpn 2>/dev/null | grep -E ":${PORT}\b" || echo "  none"
fi

echo
python3 - "$ADDR" "$PORT" <<'PYBIND'
import socket, sys
addr = sys.argv[1]
port = int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.bind((addr, port))
    print(f"bind_probe: OK {addr}:{port}")
except PermissionError as e:
    print(f"bind_probe: PERMISSION_DENIED {addr}:{port}: {e}")
    sys.exit(2)
except OSError as e:
    print(f"bind_probe: FAIL {addr}:{port}: {e}")
    sys.exit(1)
finally:
    try: s.close()
    except Exception: pass
PYBIND
