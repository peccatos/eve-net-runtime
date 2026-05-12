#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/install.sh" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found. Install Rust first: https://rustup.rs/" >&2
  exit 1
fi

for bin in ip nft systemctl wg; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "required command not found: $bin" >&2
    exit 1
  fi
done

cargo build --release

install -Dm755 target/release/eve-net /usr/local/bin/eve-net
install -d /etc/eve-net
install -d -m 700 /var/lib/eve-net

if [[ -f /etc/eve-net/policy.json ]]; then
  backup="/etc/eve-net/policy.json.bak.$(date +%Y%m%d-%H%M%S)"
  cp /etc/eve-net/policy.json "$backup"
  echo "Existing /etc/eve-net/policy.json preserved. Backup: $backup"
else
  install -Dm644 config/policy.example.json /etc/eve-net/policy.json
  echo "Installed default config: /etc/eve-net/policy.json"
fi

install -Dm644 systemd/eve-net.service /etc/systemd/system/eve-net.service
install -Dm644 systemd/eve-net-cleanup.service /etc/systemd/system/eve-net-cleanup.service
install -Dm644 systemd/eve-net-status.service /etc/systemd/system/eve-net-status.service
install -Dm644 systemd/eve-net-dns-refresh.service /etc/systemd/system/eve-net-dns-refresh.service
install -Dm644 systemd/eve-net-dns-refresh.timer /etc/systemd/system/eve-net-dns-refresh.timer
install -Dm644 systemd/eve-net-dns-prune.service /etc/systemd/system/eve-net-dns-prune.service
install -Dm644 systemd/eve-net-dns-prune.timer /etc/systemd/system/eve-net-dns-prune.timer
install -Dm644 systemd/eve-net-dns-proxy.service /etc/systemd/system/eve-net-dns-proxy.service
install -Dm644 README.md /usr/share/doc/eve-net/README.md
install -d -m 700 /etc/wireguard
install -m 600 config/wireguard/wg0.conf.template /etc/wireguard/eve-net-wg0.conf.template
install -m 600 config/wireguard/wg1.conf.template /etc/wireguard/eve-net-wg1.conf.template

systemctl daemon-reload
systemctl enable eve-net.service
systemctl enable --now eve-net-dns-refresh.timer
systemctl enable --now eve-net-dns-prune.timer

cat <<'MSG'
Installed eve-net systemd units.

Next safe sequence:
  sudo /usr/local/bin/eve-net status --config /etc/eve-net/policy.json
  sudo bash scripts/enable-apply.sh /etc/eve-net/policy.json
  sudo systemctl start eve-net.service
  systemctl status eve-net.service --no-pager
  journalctl -u eve-net.service -n 80 --no-pager

Manual cleanup:
  sudo systemctl start eve-net-cleanup.service

WireGuard templates:
  /etc/wireguard/eve-net-wg0.conf.template
  /etc/wireguard/eve-net-wg1.conf.template
  sudo /usr/local/bin/eve-net wg-status --config /etc/eve-net/policy.json

Tunnel/domain diagnostics:
  sudo /usr/local/bin/eve-net tunnel-detect
  sudo /usr/local/bin/eve-net domain-resolve --config /etc/eve-net/policy.json

Policy reload/reconcile:
  sudo /usr/local/bin/eve-net reconcile --config /etc/eve-net/policy.json --apply
  sudo bash scripts/reload-policy.sh /etc/eve-net/policy.json

DNS cache:
  sudo /usr/local/bin/eve-net dns-cache --config /etc/eve-net/policy.json
  sudo /usr/local/bin/eve-net dns-refresh --config /etc/eve-net/policy.json --apply
  sudo /usr/local/bin/eve-net dns-prune --config /etc/eve-net/policy.json --apply
  systemctl list-timers 'eve-net-dns-*' --no-pager

DNS interception v0.10 (disabled by default):
  sudo /usr/local/bin/eve-net dns-intercept-status --config /etc/eve-net/policy.json
  sudo bash scripts/enable-dns-interception-config.sh /etc/eve-net/policy.json
  sudo systemctl start eve-net-dns-proxy.service
  bash scripts/dns-proxy-port-check.sh 5533
  sudo bash scripts/amnezia-dns-detect.sh  # optional, useful when Amnezia blocks public DNS/53
  bash scripts/dns-proxy-status.sh /etc/eve-net/policy.json
  bash scripts/dns-upstream-policy-check.sh /etc/eve-net/policy.json
  bash scripts/dns-upstream-test.sh 111.88.96.50:53 example.com  # optional upstream probe
  bash scripts/dns-proxy-self-test.sh /etc/eve-net/policy.json example.com
  bash scripts/dns-proxy-test.sh example.com
  bash scripts/dns-proxy-aaaa-deny-test.sh /etc/eve-net/policy.json example.com
  bash scripts/dns-proxy-cache-write-test.sh /etc/eve-net/policy.json example.com
  bash scripts/dns-proxy-deny-domain-test.sh /etc/eve-net/policy.json
  bash scripts/dns-proxy-safe-stop.sh

Host DNS integration v0.11 (safe/dry-run first):
  bash scripts/host-dns-detect.sh
  bash scripts/host-dns-plan.sh /etc/eve-net/policy.json
  sudo bash scripts/enable-host-dns-config.sh /etc/eve-net/policy.json auto
  sudo systemctl restart eve-net-dns-proxy.service
  # Apply is intentionally gated; run only after plan/proxy checks pass.
  sudo bash scripts/host-dns-apply.sh /etc/eve-net/policy.json --apply auto --i-understand-this-can-break-dns
  sudo bash scripts/host-dns-rollback.sh
  sudo bash scripts/host-dns-emergency-restore.sh

Validation:
  sudo /usr/local/bin/eve-net validate --config /etc/eve-net/policy.json
  bash scripts/test-fail-closed.sh /etc/eve-net/policy.json
  bash scripts/dns-fail-closed-semantics.sh /etc/eve-net/policy.json
  bash scripts/prepare-dns-interception.sh
MSG
