#!/usr/bin/env bash
set -euo pipefail
journalctl -u eve-net.service -f
