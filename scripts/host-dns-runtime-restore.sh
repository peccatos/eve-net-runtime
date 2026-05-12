#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT="${1:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/host-dns-runtime-restore.sh /var/lib/eve-net/host-dns-runtime-snapshots/<timestamp>.json" >&2
  exit 1
fi

if [[ -z "$SNAPSHOT" || ! -f "$SNAPSHOT" ]]; then
  echo "missing snapshot path" >&2
  exit 1
fi

if ! command -v resolvectl >/dev/null 2>&1; then
  echo "missing command: resolvectl" >&2
  exit 1
fi

python3 - "$SNAPSHOT" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

snapshot_path = Path(sys.argv[1])
snapshot = json.loads(snapshot_path.read_text())
links = snapshot.get("links", {})


def link_exists(name):
    return Path("/sys/class/net", name).exists()


def run(argv, check=True):
    print("+ " + " ".join(argv))
    proc = subprocess.run(argv, text=True)
    if check and proc.returncode != 0:
        raise SystemExit(proc.returncode)
    return proc.returncode


for link, state in links.items():
    if not link_exists(link):
        print(f"skip missing link: {link}", file=sys.stderr)
        continue

    dns_servers = state.get("dns_servers") or []
    dns_domains = state.get("dns_domains") or []
    default_route = state.get("default_route")

    run(["resolvectl", "dns", link] + (dns_servers if dns_servers else [""]))
    run(["resolvectl", "domain", link] + (dns_domains if dns_domains else [""]))

    if default_route in {"yes", "no"}:
        run(["resolvectl", "default-route", link, default_route])
    else:
        print(f"skip default-route restore for {link}: snapshot value is {default_route!r}", file=sys.stderr)

run(["resolvectl", "flush-caches"], check=False)
PY

echo
echo "final resolvectl status:"
set +o pipefail
resolvectl status | head -n 100
set -o pipefail
