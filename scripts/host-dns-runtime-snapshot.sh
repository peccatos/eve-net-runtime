#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
SNAPSHOT_ROOT="/var/lib/eve-net/host-dns-runtime-snapshots"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
SNAPSHOT="$SNAPSHOT_ROOT/$STAMP.json"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/host-dns-runtime-snapshot.sh /etc/eve-net/policy.json" >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "missing config: $CONFIG" >&2
  exit 1
fi

if ! command -v resolvectl >/dev/null 2>&1; then
  echo "missing command: resolvectl" >&2
  exit 1
fi

install -d -m 700 "$SNAPSHOT_ROOT"

python3 - "$CONFIG" "$SNAPSHOT" "$STAMP" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
snapshot_path = Path(sys.argv[2])
stamp = sys.argv[3]


def run(argv):
    proc = subprocess.run(argv, text=True, capture_output=True)
    return {
        "cmd": argv,
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def parse_value_list(text):
    text = text.strip()
    if not text:
        return []
    if ":" in text:
        text = text.split(":", 1)[1].strip()
    if not text or text == "-":
        return []
    return text.split()


def parse_default_route(text):
    values = parse_value_list(text)
    if not values:
        return None
    first = values[0].strip().lower()
    if first in {"yes", "no"}:
        return first
    return first


def link_exists(name):
    return Path("/sys/class/net", name).exists()


cfg = json.loads(config_path.read_text())

links = []
underlay = cfg.get("wifi_underlay", {}).get("interface") or "wlo1"
for candidate in (underlay, "wlo1"):
    if candidate and candidate not in links and link_exists(candidate):
        links.append(candidate)

if link_exists("amn0") and "amn0" not in links:
    links.append("amn0")

link_snapshots = {}
for link in links:
    dns_result = run(["resolvectl", "dns", link])
    domain_result = run(["resolvectl", "domain", link])
    default_route_result = run(["resolvectl", "default-route", link])
    link_snapshots[link] = {
        "exists": link_exists(link),
        "dns_servers": parse_value_list(dns_result["stdout"]) if dns_result["ok"] else [],
        "dns_domains": parse_value_list(domain_result["stdout"]) if domain_result["ok"] else [],
        "default_route": parse_default_route(default_route_result["stdout"]) if default_route_result["ok"] else None,
        "raw": {
            "dns": dns_result,
            "domain": domain_result,
            "default_route": default_route_result,
        },
    }

resolv_conf = {
    "path": "/etc/resolv.conf",
    "exists": Path("/etc/resolv.conf").exists() or Path("/etc/resolv.conf").is_symlink(),
    "is_symlink": Path("/etc/resolv.conf").is_symlink(),
    "symlink_target": None,
    "symlink_target_abs": None,
}
if resolv_conf["is_symlink"]:
    try:
        resolv_conf["symlink_target"] = os.readlink("/etc/resolv.conf")
    except OSError:
        resolv_conf["symlink_target"] = None
    resolv_conf["symlink_target_abs"] = os.path.realpath("/etc/resolv.conf")

snapshot = {
    "schema": "eve-net.host_dns_runtime_snapshot.v1",
    "timestamp": stamp,
    "config_path": str(config_path),
    "resolvectl_status": run(["resolvectl", "status"])["stdout"],
    "links": link_snapshots,
    "resolv_conf": resolv_conf,
    "dns_interception": {
        "listen_addr": cfg.get("dns_interception", {}).get("listen_addr", ""),
        "upstream_addr": cfg.get("dns_interception", {}).get("upstream_addr", ""),
        "upstreams": cfg.get("dns_interception", {}).get("upstreams", []),
    },
}

snapshot_path.write_text(json.dumps(snapshot, indent=2, ensure_ascii=False) + "\n")
os.chmod(snapshot_path, 0o600)
print(snapshot_path)
PY
