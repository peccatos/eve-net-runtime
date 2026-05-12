#!/usr/bin/env bash
set -euo pipefail
sudo cargo run -- status --config config/policy.example.json
