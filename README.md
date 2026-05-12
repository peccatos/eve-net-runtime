# eve-net runtime v0.11.4

Linux policy-routing runtime for controlled egress selection across a Wi-Fi underlay, direct egress, tunnel egress, and optional local DNS control.

This repository ships example interface names and addresses in `config/policy.example.json` and in the command snippets below. Replace them with values from your host before applying anything with `sudo` or `--apply`.

Reference topology used in the examples:

- Wi-Fi underlay example: `wlo1`
- Direct egress example: table/fwmark `100`
- Tunnel egress example: `amn0`, table/fwmark `250`
- WireGuard template examples: `wg0`, `wg1`

## What works

- dry-run mode
- guarded `--apply`
- nftables output marking
- fwmark → route table
- idempotent route/rule reconciliation
- `status`
- `cleanup`
- nft counters
- systemd service lifecycle
- WireGuard diagnostics and templates
- tunnel detection: `amn0`, `tun0`, `wg0`
- domain policies via DNS-to-IPv4 resolution
- DNS cache file with operator TTL/refresh window
- `dns-cache`, `dns-refresh`, `dns-prune`
- systemd DNS refresh/prune timers
- `validate`
- explicit DNS fail-closed semantics

## DNS fail-closed semantics

v0.10.5 is intentionally honest about DNS-domain safety and includes an explicit local DNS proxy test layer.

A domain policy is resolved during reconciliation, cached, then converted into normal IPv4 nft rules:

```text
example.com -> A records -> ip daddr <resolved-ip> meta mark set <fwmark>
```

This is useful and works, but it is **L3 policy routing**, not a DNS firewall.

### Soft fail-closed at L3

Default:

```json
"dns_cache": {
  "enabled": true,
  "path": "/var/lib/eve-net/dns-cache.json",
  "ttl_sec": 300,
  "stale_grace_sec": 3600,
  "fail_closed_unresolved": true,
  "unresolved_domain_mode": "soft_fail_closed_l3",
  "dns_interception_enabled": false
}
```

Meaning:

- if a domain cannot be resolved, eve-net creates no nft route rule for it
- this avoids routing unknown IPs through the wrong egress
- it does **not** hard-block future DNS answers from some other resolver path
- true hard fail-closed requires DNS interception / DNS proxy / DNS deny support

### Allow stale mode

```json
"unresolved_domain_mode": "allow_stale"
```

Meaning:

- if live DNS fails, stale cached IPs may be used during `stale_grace_sec`
- better continuity
- weaker strictness

### Hard fail-closed mode

```json
"unresolved_domain_mode": "hard_fail_closed_dns_required",
"dns_interception_enabled": true
```

This is a readiness flag for a future DNS interception layer. v0.10.5 includes a local DNS proxy, but host-wide DNS redirection is still disabled by default. Test explicitly against `127.0.0.1:5533`.

Run:

```bash
bash scripts/dns-fail-closed-semantics.sh /etc/eve-net/policy.json
bash scripts/prepare-dns-interception.sh
```

## DNS cache model

`dns_cache.ttl_sec` is not authoritative DNS TTL from the resolver. The Rust standard resolver does not expose TTL, so eve-net uses an operator-defined refresh window.

Behavior:

- fresh cache entry: reused
- expired cache entry: live DNS refresh attempted
- live DNS success: cache updated
- live DNS failure + `soft_fail_closed_l3`: domain policy produces no nft rule
- live DNS failure + `allow_stale`: stale cache may be used during `stale_grace_sec`

Commands:

```bash
sudo /usr/local/bin/eve-net dns-cache --config /etc/eve-net/policy.json
sudo /usr/local/bin/eve-net dns-refresh --config /etc/eve-net/policy.json --apply
sudo /usr/local/bin/eve-net dns-prune --config /etc/eve-net/policy.json --apply
sudo /usr/local/bin/eve-net validate --config /etc/eve-net/policy.json
```

Timers:

```bash
systemctl list-timers 'eve-net-dns-*' --no-pager
bash scripts/dns-timers-status.sh
```

## Local commands

Preflight:

```bash
bash scripts/preflight.sh config/policy.example.json
```

Local dry-run:

```bash
cargo run -- run --config config/policy.example.json --once --verbose
```

Local apply:

```bash
bash scripts/enable-apply.sh config/policy.example.json
sudo cargo run -- run --config config/policy.example.json --apply --once --verbose
```

Status:

```bash
sudo cargo run -- status --config config/policy.example.json
cargo run -- tunnel-detect
cargo run -- wg-status --config config/policy.example.json
cargo run -- domain-resolve --config config/policy.example.json
cargo run -- domain-resolve --config config/policy.example.json example.com
```

Cleanup:

```bash
sudo cargo run -- cleanup --config config/policy.example.json --apply --verbose
```

## systemd install

```bash
sudo bash scripts/install.sh
sudo bash scripts/enable-apply.sh /etc/eve-net/policy.json
sudo systemctl start eve-net.service
systemctl status eve-net.service --no-pager -l
sudo /usr/local/bin/eve-net status --config /etc/eve-net/policy.json
```

Cleanup service:

```bash
bash scripts/systemd-cleanup.sh
```

Uninstall:

```bash
sudo bash scripts/uninstall.sh
```

## Amnezia tunnel workflow

If Amnezia creates `amn0`, enable it as a tunnel egress:

```bash
ip -br link show | grep -E '^(amn0|tun0|wg0)\b'
sudo bash scripts/enable-amnezia-policy.sh /etc/eve-net/policy.json amn0
sudo systemctl restart eve-net.service
sudo /usr/local/bin/eve-net status --config /etc/eve-net/policy.json
```

Add a domain policy through the Amnezia tunnel:

```bash
sudo bash scripts/add-domain-policy.sh /etc/eve-net/policy.json example.com amn0
sudo /usr/local/bin/eve-net domain-resolve --config /etc/eve-net/policy.json example.com
sudo /usr/local/bin/eve-net dns-refresh --config /etc/eve-net/policy.json --apply
sudo /usr/local/bin/eve-net reconcile --config /etc/eve-net/policy.json --apply
sudo /usr/local/bin/eve-net status --config /etc/eve-net/policy.json
```

Test split routing:

```bash
ip route get 1.1.1.1 mark 250
ip route get 8.8.8.8 mark 100
```

## WireGuard provider

v0.10.5 does not create a VPN account or server. It provides runtime hooks and safe templates.

Check tools/status:

```bash
bash scripts/wg-status.sh /etc/eve-net/policy.json
```

Install templates:

```bash
sudo bash scripts/install-wireguard-templates.sh
```

Create a real `wg0.conf` from the template:

```bash
sudo cp /etc/wireguard/eve-net-wg0.conf.template /etc/wireguard/wg0.conf
sudo nano /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
sudo wg-quick up wg0
```

Enable `wg0` in eve-net config only after the interface is real:

```bash
sudo bash scripts/enable-wg-policy.sh /etc/eve-net/policy.json wg0
sudo systemctl restart eve-net.service
sudo /usr/local/bin/eve-net status --config /etc/eve-net/policy.json
```

## Phase 0.10.2 — DNS interception proxy

`eve-net` v0.10.2 adds a local UDP DNS proxy, disabled by default.

What it does:

- listens on `127.0.0.1:5533`
- forwards DNS queries to `dns_interception.upstreams` in order, or `dns_interception.upstream_addr` when no list is configured
- recognizes enabled domain policies
- can deny AAAA queries for policy domains to avoid IPv6 bypass
- can hard-fail-close unresolved policy domains at the DNS layer
- can write accepted A answers into `/var/lib/eve-net/dns-cache.json`

What it does **not** do in v0.10.2:

- it does not rewrite `/etc/resolv.conf`
- it does not change NetworkManager DNS settings
- it does not install nft DNS redirect rules automatically
- it does not intercept DoH/DoT inside browsers

Safe test flow:

```bash
sudo /usr/local/bin/eve-net dns-intercept-status --config /etc/eve-net/policy.json
sudo bash scripts/enable-dns-interception-config.sh /etc/eve-net/policy.json
sudo systemctl start eve-net-dns-proxy.service
bash scripts/dns-proxy-test.sh example.com
journalctl -u eve-net-dns-proxy.service -n 80 --no-pager -l
```

The service is installed but not enabled by default. Host-wide DNS interception is a later phase.

## Phase 0.10.3 — Amnezia DNS upstream compatibility

Amnezia can install nftables rules that reject generic outbound DNS/53 and only allow its own DNS servers through `amn0`/`tun*`.
If `eve-net-dns-proxy` starts but `dns-proxy-test.sh` returns `rcode=5`, inspect the journal:

```bash
journalctl -u eve-net-dns-proxy.service -n 80 --no-pager -l
```

If you see `Operation not permitted`, detect the Amnezia-allowed upstream DNS servers:

```bash
sudo bash scripts/amnezia-dns-detect.sh
sudo bash scripts/enable-dns-interception-config.sh /etc/eve-net/policy.json auto
sudo systemctl restart eve-net-dns-proxy.service
bash scripts/dns-proxy-test.sh example.com
```

You can also force an upstream:

```bash
sudo bash scripts/enable-dns-interception-config.sh /etc/eve-net/policy.json 111.88.96.50:53
bash scripts/dns-upstream-test.sh 111.88.96.50:53 example.com
```

## v0.10.4 Amnezia DNS upstream detection

If Amnezia blocks public DNS/53, use provider DNS detected from nft rules:

```bash
sudo bash scripts/amnezia-dns-detect.sh
sudo bash scripts/enable-dns-interception-config.sh /etc/eve-net/policy.json auto
sudo systemctl restart eve-net-dns-proxy.service
bash scripts/dns-proxy-self-test.sh /etc/eve-net/policy.json example.com
```

If auto-detect fails, set the upstream manually:

```bash
sudo bash scripts/enable-dns-interception-config.sh /etc/eve-net/policy.json 111.88.96.50:53
sudo systemctl restart eve-net-dns-proxy.service
bash scripts/dns-proxy-test.sh example.com
```


## DNS proxy / interception foundation

v0.10.5 includes a local UDP DNS proxy for explicit tests:

```bash
sudo bash scripts/enable-dns-interception-config.sh /etc/eve-net/policy.json auto
sudo systemctl restart eve-net-dns-proxy.service
bash scripts/dns-proxy-self-test.sh /etc/eve-net/policy.json example.com
```

The proxy listens on `127.0.0.1:5533` by default. It does **not** rewrite `/etc/resolv.conf`, NetworkManager, or systemd-resolved.

Useful commands:

```bash
bash scripts/dns-proxy-status.sh /etc/eve-net/policy.json
sudo bash scripts/amnezia-dns-detect.sh
bash scripts/dns-upstream-health.sh /etc/eve-net/policy.json example.com
bash scripts/dns-proxy-failover-test.sh /etc/eve-net/policy.json example.com
bash scripts/dns-upstream-policy-check.sh /etc/eve-net/policy.json
bash scripts/dns-proxy-test.sh example.com A
bash scripts/dns-proxy-aaaa-deny-test.sh /etc/eve-net/policy.json example.com
bash scripts/dns-proxy-cache-write-test.sh /etc/eve-net/policy.json example.com
bash scripts/dns-proxy-deny-domain-test.sh /etc/eve-net/policy.json
bash scripts/dns-proxy-safe-stop.sh
```

With Amnezia, public DNS/53 may be blocked. Use the provider DNS detected from `amnvpn.*allowDNS` rules, for example:

```bash
sudo bash scripts/enable-dns-interception-config.sh /etc/eve-net/policy.json auto
```

Host-wide redirect remains a later phase.

## v0.11.3 DNS proxy upstream failover

`dns_interception.upstream_addr` remains the backward-compatible primary upstream. `dns_interception.upstreams` can now hold an ordered failover list:

```json
"dns_interception": {
  "upstream_addr": "111.88.96.50:53",
  "upstreams": [
    "111.88.96.50:53",
    "111.88.96.51:53"
  ]
}
```

Resolution order:

1. If `upstreams` exists and is non-empty, the proxy tries those entries in order.
2. Otherwise it uses `upstream_addr`.
3. Duplicate upstreams are collapsed.
4. Malformed `upstreams` entries are ignored and shown as validation warnings.

Each upstream gets `dns_interception.timeout_ms`. Transport errors and timeouts are logged with the upstream address, then the proxy tries the next upstream. If all upstreams fail, normal DNS names return `SERVFAIL`; hard fail-closed policy domains keep the existing `REFUSED` behavior where configured.

Amnezia auto mode writes both fields:

```bash
sudo bash scripts/amnezia-dns-detect.sh
sudo bash scripts/enable-dns-interception-config.sh /etc/eve-net/policy.json auto
sudo systemctl restart eve-net-dns-proxy.service
bash scripts/dns-upstream-health.sh /etc/eve-net/policy.json example.com
bash scripts/dns-proxy-failover-test.sh /etc/eve-net/policy.json example.com
```

These diagnostics do not edit `/etc/resolv.conf`, NetworkManager, systemd-resolved link DNS, or systemd enablement.

## v0.11.4 Direct egress refresh

Wi-Fi DHCP can change the host address while `/etc/eve-net/policy.json` still contains an old direct egress `source_ip`. If reconcile uses that stale address, Linux can reject the route update with `Invalid prefsrc address` before nft rules are restored.

Direct egress refresh is scoped only to enabled `kind="direct"` egress interfaces. It reads the current host state with:

```bash
ip -j route show default dev wlo1
ip -j -4 addr show dev wlo1
```

Dry-run:

```bash
sudo /usr/local/bin/eve-net refresh-direct-egress --config /etc/eve-net/policy.json
```

Apply to config:

```bash
sudo /usr/local/bin/eve-net refresh-direct-egress --config /etc/eve-net/policy.json --apply
sudo bash scripts/refresh-direct-egress.sh /etc/eve-net/policy.json
```

Reconcile also has an in-memory safety guard. With `runtime.auto_refresh_direct_egress=true`, reconcile uses the runtime gateway/source IP for direct egress route operations when drift is detected, without writing the config. This avoids calling `ip route replace ... src <stale-ip>`.

Acceptance:

```bash
cargo check
bash -n scripts/*.sh
bash scripts/preflight.sh config/policy.example.json
sudo /usr/local/bin/eve-net validate --config /etc/eve-net/policy.json
sudo /usr/local/bin/eve-net refresh-direct-egress --config /etc/eve-net/policy.json --apply
sudo /usr/local/bin/eve-net reconcile --config /etc/eve-net/policy.json --apply
sudo /usr/local/bin/eve-net status --config /etc/eve-net/policy.json
```


## Phase 0.11 — Host DNS integration safe mode

v0.11 adds cautious host DNS integration around the local DNS proxy. It does **not** rewrite the host resolver automatically.

Important: `/etc/resolv.conf` and NetworkManager DNS settings cannot specify port `5533`. For host-wide DNS, the eve-net DNS proxy must listen on `127.0.0.1:53`.

Recommended flow:

```bash
bash scripts/host-dns-detect.sh
bash scripts/host-dns-plan.sh /etc/eve-net/policy.json
sudo bash scripts/enable-host-dns-config.sh /etc/eve-net/policy.json auto
sudo systemctl restart eve-net-dns-proxy.service
sudo bash scripts/host-dns-apply.sh /etc/eve-net/policy.json --apply auto --i-understand-this-can-break-dns
bash scripts/host-dns-status.sh /etc/eve-net/policy.json
```

Rollback:

```bash
sudo bash scripts/host-dns-rollback.sh
```

Safety rules:

- `host-dns-apply.sh` refuses to run unless the DNS proxy is active on `127.0.0.1:53`.
- It creates a runtime snapshot under `/var/lib/eve-net/host-dns-runtime-snapshots/<timestamp>.json` before mutating DNS settings.
- `auto` prefers systemd-resolved runtime DNS on `wlo1` and `amn0` when present; legacy NetworkManager and resolv.conf methods remain explicit.
- `host-dns-safe-stop.sh` refuses to stop the DNS proxy if `/etc/resolv.conf` points at `127.0.0.1`, unless `--force` is passed.

## Phase 0.11.1 — recovery-first host DNS guardrails

After host DNS integration testing, v0.11.1 makes host DNS apply intentionally harder to run.

Apply now requires explicit acknowledgement:

```bash
sudo bash scripts/host-dns-apply.sh /etc/eve-net/policy.json --apply auto --i-understand-this-can-break-dns
```

The script will:

1. require `dns_interception.listen_addr=127.0.0.1:53`,
2. require `eve-net-dns-proxy.service` active,
3. require a UDP listener on `127.0.0.1:53`,
4. test the local proxy before changing host DNS,
5. create a runtime snapshot under `/var/lib/eve-net/host-dns-runtime-snapshots`,
6. apply systemd-resolved runtime DNS on `wlo1` and `amn0` when present,
7. test the proxy again,
8. test host DNS with `getent`,
9. restore the runtime snapshot on failure and run repair if host DNS is still broken.

Emergency restore without a backup:

```bash
sudo bash scripts/host-dns-emergency-restore.sh
```

This stops the eve-net DNS proxy and resets active NetworkManager connections to automatic DNS.

## Host DNS integration safety model

`127.0.0.1:5533` is the safe explicit test mode. Use it for direct proxy checks without changing host resolver state.

`127.0.0.1:53` is host integration mode. In this mode systemd-resolved links can be pointed at the local eve-net DNS proxy:

```bash
sudo resolvectl dns wlo1 127.0.0.1
sudo resolvectl domain wlo1 '~.'
sudo resolvectl default-route wlo1 yes
```

On Fedora/systemd-resolved/NetworkManager/Amnezia setups, `resolvectl revert` is not a safe rollback primitive for every host. It can leave links with no DNS servers and `DefaultRoute=no`.

The default rollback mechanism is now runtime snapshot/restore:

```bash
sudo bash scripts/host-dns-runtime-snapshot.sh /etc/eve-net/policy.json
sudo bash scripts/host-dns-rollback.sh --latest
```

Snapshots are written to `/var/lib/eve-net/host-dns-runtime-snapshots/` and include `resolvectl status`, per-link DNS servers, domains, default-route flags, `/etc/resolv.conf` symlink state, and the configured DNS proxy listen/upstream addresses.

Repair mode restores the known-good eve-net DNS path: `dns_interception.enabled=true`, `listen_addr=127.0.0.1:53`, a valid upstream, `dns_cache.dns_interception_enabled=true`, hard DNS fail-closed mode, `eve-net-dns-proxy.service`, and runtime `resolvectl` DNS settings for `wlo1` plus `amn0` when present.

```bash
sudo bash scripts/host-dns-runtime-repair.sh /etc/eve-net/policy.json
sudo bash scripts/test-host-dns-runtime-rollback.sh /etc/eve-net/policy.json
```
