# eve-net v0.10.2

## Fixes

- Changed the default DNS proxy listen address from `127.0.0.1:5353` to `127.0.0.1:5533`.
- Port `5353` is commonly used by mDNS/Avahi, so binding to it can fail with `Address already in use`.
- Removed an unused DNS RCODE constant that produced a Rust warning.
- Added `scripts/dns-proxy-port-check.sh`.
- `scripts/enable-dns-interception-config.sh` now forces `listen_addr` to `127.0.0.1:5533` to repair older configs.

## Notes

`v0.10.2` still does not modify `/etc/resolv.conf`, NetworkManager, or install host-wide nft DNS redirect rules automatically.
