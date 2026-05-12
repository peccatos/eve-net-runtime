#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-config/policy.example.json}"

if [[ ! -f "$CONFIG" ]]; then
  echo "Config not found: $CONFIG" >&2
  exit 1
fi

python3 - "$CONFIG" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
cfg = json.loads(path.read_text())
cfg.setdefault("runtime", {})["dry_run"] = False
path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"runtime.dry_run=false written to {path}")
PY
