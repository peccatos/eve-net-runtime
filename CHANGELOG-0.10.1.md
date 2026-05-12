# eve-net v0.10.2

Fixes:
- Enables Tokio `net` feature so `tokio::net::UdpSocket` compiles.
- Improves `scripts/dns-proxy-test.sh` timeout diagnostics when the DNS proxy service is not running.

Notes:
- `dns-proxy-test.sh` must be run after `eve-net-dns-proxy.service` is started.
- v0.10.2 still does not modify system DNS automatically.
