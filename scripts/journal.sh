#!/usr/bin/env bash
set -euo pipefail
journalctl -u eve-net.service -n "${1:-120}" --no-pager
