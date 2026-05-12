# eve-net v0.11.1

Recovery-first hardening for host DNS integration after a real DNS outage test.

Changes:
- `host-dns-apply.sh` now requires explicit `--i-understand-this-can-break-dns` acknowledgement.
- `host-dns-apply.sh` performs local proxy canary tests before and after applying host DNS changes.
- `host-dns-apply.sh` automatically rolls back if host DNS validation fails.
- Added `host-dns-emergency-restore.sh` for no-backup recovery.
- `host-dns-safe-stop.sh` checks both `/etc/resolv.conf` and NetworkManager for `127.0.0.1` DNS before stopping proxy.
- `host-dns-rollback.sh` falls back to emergency restore when no backup exists.

Host DNS integration remains unsafe-by-default and must not be used without a tested local proxy on `127.0.0.1:53`.
