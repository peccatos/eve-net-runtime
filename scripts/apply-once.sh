#!/usr/bin/env bash
set -euo pipefail
sudo cargo run -- run --config config/policy.example.json --apply --once --verbose
