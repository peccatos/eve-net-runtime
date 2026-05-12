#!/usr/bin/env bash
set -euo pipefail
sudo cargo run -- cleanup --config config/policy.example.json --apply --verbose
