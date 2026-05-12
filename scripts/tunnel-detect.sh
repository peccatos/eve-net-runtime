#!/usr/bin/env bash
set -euo pipefail
if command -v /usr/local/bin/eve-net >/dev/null 2>&1; then
  /usr/local/bin/eve-net tunnel-detect
else
  cargo run -- tunnel-detect
fi
