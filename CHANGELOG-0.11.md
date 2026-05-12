# EVE Net Runtime v0.11

Host DNS integration safe mode.

## Added

- `scripts/host-dns-detect.sh`
- `scripts/host-dns-plan.sh`
- `scripts/host-dns-bind-check.sh`
- `scripts/enable-host-dns-config.sh`
- `scripts/host-dns-backup.sh`
- `scripts/host-dns-apply.sh`
- `scripts/host-dns-rollback.sh`
- `scripts/host-dns-status.sh`
- `scripts/host-dns-safe-stop.sh`

## Safety posture

- No automatic host DNS mutation during install.
- Host DNS apply requires explicit `--apply`.
- Host integration requires DNS proxy on `127.0.0.1:53` because system resolvers do not support `nameserver 127.0.0.1:5533`.
- Backup is created before mutation.
- Rollback script restores NetworkManager DNS fields and regular `/etc/resolv.conf` where possible.

## Not yet included

- nft DNS redirect.
- automatic NetworkManager dispatcher integration.
- system-wide DoH/DoT enforcement.
