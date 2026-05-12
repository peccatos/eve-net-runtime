#!/usr/bin/env bash
set -euo pipefail

echo "Stopping eve-net.service before cleanup..."
sudo systemctl stop eve-net.service 2>/dev/null || true

echo "Running eve-net-cleanup.service..."
sudo systemctl start eve-net-cleanup.service
journalctl -u eve-net-cleanup.service -n 80 --no-pager

echo
echo "Cleanup finished. eve-net.service is intentionally stopped."
echo "Start it again with: sudo systemctl start eve-net.service"
