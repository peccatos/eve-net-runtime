# eve-net v0.10.4

DNS proxy hardening for Amnezia environments.

## Fixed

- Fixed `scripts/amnezia-dns-detect.sh` so it no longer accidentally feeds the raw nft ruleset to Python as source code.
- Fixed `scripts/enable-dns-interception-config.sh auto` so it can actually select Amnezia-allowed DNS upstreams from nft rules.
- Avoided fragile full-ruleset parsing by reading nft rules from a temporary text file and parsing only DNS allow rules.

## Added

- `scripts/dns-proxy-self-test.sh`
- `scripts/dns-upstream-policy-check.sh`

## Operational note

Amnezia may reject public DNS/53 and only allow provider DNS such as `111.88.96.50:53` / `111.88.96.51:53` through `amn0`.
