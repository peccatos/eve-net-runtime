# eve-net v0.10.3

Fixes DNS proxy upstream compatibility with Amnezia VPN firewall rules.

## Added

- `scripts/amnezia-dns-detect.sh`
- `scripts/dns-upstream-test.sh`
- `enable-dns-interception-config.sh` auto-detects Amnezia-allowed DNS upstreams from nftables rules.
- `dns-proxy-test.sh` now explains DNS `rcode=5` as likely upstream REFUSED/fail-closed behavior.

## Why

Amnezia may reject generic outbound DNS/53 while allowing only its own DNS servers, for example `111.88.96.50:53` and `111.88.96.51:53`, through `amn0`. Using `1.1.1.1:53` or `9.9.9.9:53` can therefore fail with `EPERM`.
