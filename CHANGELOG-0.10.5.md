# eve-net v0.10.5

DNS interception readiness hardening.

## Added

- Robust Amnezia blockDNS detection in `scripts/dns-upstream-policy-check.sh`.
- DNS proxy self-test now checks:
  - upstream reachability
  - proxy A query
  - proxy AAAA deny behavior for policy domains
  - unresolved policy-domain deny behavior
  - DNS cache write/update after proxy query
- New scripts:
  - `scripts/dns-proxy-status.sh`
  - `scripts/dns-proxy-safe-stop.sh`
  - `scripts/dns-proxy-deny-domain-test.sh`
  - `scripts/dns-proxy-aaaa-deny-test.sh`
  - `scripts/dns-proxy-cache-write-test.sh`

## Notes

Host-wide DNS redirection remains disabled by default. v0.10.5 still tests the local proxy explicitly on `127.0.0.1:5533`.
