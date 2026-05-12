#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/eve-net/policy.json}"
APPLY=""
METHOD="auto"
ACK=""
LEGACY_REVERT=0

if [[ $# -gt 0 ]]; then
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY="--apply"
      shift
      if [[ $# -gt 0 && "$1" != --* ]]; then
        METHOD="$1"
        shift
      fi
      ;;
    --i-understand-this-can-break-dns)
      ACK="--i-understand-this-can-break-dns"
      shift
      ;;
    --legacy-revert)
      LEGACY_REVERT=1
      echo "WARNING: legacy revert is unsafe on Fedora/systemd-resolved/NetworkManager/Amnezia setups" >&2
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

if [[ "$APPLY" != "--apply" ]]; then
  echo "dry-run only. To apply: sudo bash scripts/host-dns-apply.sh $CONFIG --apply [auto|resolved|nm|resolvconf] --i-understand-this-can-break-dns"
  echo
  bash scripts/host-dns-plan.sh "$CONFIG"
  exit 0
fi

if [[ "$ACK" != "--i-understand-this-can-break-dns" ]]; then
  cat >&2 <<MSG
BLOCKED: host DNS apply requires explicit acknowledgement.
Run only after host-dns-plan, host-dns-backup, and proxy tests pass:
  sudo bash scripts/host-dns-apply.sh $CONFIG --apply $METHOD --i-understand-this-can-break-dns

Emergency restore:
  sudo bash scripts/host-dns-runtime-repair.sh $CONFIG
MSG
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/host-dns-apply.sh $CONFIG --apply $METHOD --i-understand-this-can-break-dns" >&2
  exit 1
fi

json_get() {
  local file="$1" expr="$2"
  python3 - "$file" "$expr" <<'PYJSON'
import json, sys
p, expr = sys.argv[1], sys.argv[2]
obj = json.load(open(p))
cur = obj
for part in expr.split('.'):
    if not part:
        continue
    if isinstance(cur, dict):
        cur = cur.get(part)
    else:
        cur = None
        break
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PYJSON
}

LISTEN="$(json_get "$CONFIG" dns_interception.listen_addr)"
UPSTREAM="$(json_get "$CONFIG" dns_interception.upstream_addr)"
if [[ "$LISTEN" != "127.0.0.1:53" ]]; then
  echo "BLOCKED: dns_interception.listen_addr must be 127.0.0.1:53 for host DNS integration" >&2
  echo "run: sudo bash scripts/enable-host-dns-config.sh $CONFIG auto" >&2
  exit 1
fi

if ! systemctl is-active --quiet eve-net-dns-proxy.service; then
  echo "BLOCKED: eve-net-dns-proxy.service is not active" >&2
  echo "run: sudo systemctl restart eve-net-dns-proxy.service" >&2
  exit 1
fi

if ! ss -ulpn 2>/dev/null | grep -q '127\.0\.0\.1:53\b'; then
  echo "BLOCKED: no UDP listener on 127.0.0.1:53" >&2
  echo "check: systemctl status eve-net-dns-proxy.service --no-pager -l" >&2
  exit 1
fi

# Canary test the local proxy directly before touching host DNS.
python3 - <<'PYDNS'
import socket, struct, random, sys
server=("127.0.0.1",53)
domain="example.com"
tid=random.randint(0,65535)
q=struct.pack("!HHHHHH",tid,0x0100,1,0,0,0)
for part in domain.split('.'):
    q += bytes([len(part)]) + part.encode()
q += b"\x00" + struct.pack("!HH",1,1)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.settimeout(2)
try:
    s.sendto(q,server)
    data,_=s.recvfrom(512)
    rcode=data[3] & 0x0f
    an=struct.unpack("!H",data[6:8])[0]
    if rcode != 0 or an < 1:
        print(f"BLOCKED: local DNS proxy canary failed rcode={rcode} answers={an}", file=sys.stderr)
        sys.exit(1)
    print(f"local DNS proxy canary: PASS rcode={rcode} answers={an}")
except Exception as e:
    print(f"BLOCKED: local DNS proxy canary failed: {e!r}", file=sys.stderr)
    sys.exit(1)
PYDNS

SNAPSHOT_PATH="$(bash scripts/host-dns-runtime-snapshot.sh "$CONFIG")"
echo "runtime snapshot: $SNAPSHOT_PATH"

BACKUP_DIR="$(bash scripts/host-dns-backup.sh)"
echo "backup: $BACKUP_DIR"
install -d -m 700 /var/lib/eve-net
cat > /var/lib/eve-net/host-dns-emergency-restore.txt <<EOFRESTORE
sudo bash $(pwd)/scripts/host-dns-runtime-restore.sh $SNAPSHOT_PATH
sudo bash $(pwd)/scripts/host-dns-runtime-repair.sh $CONFIG
EOFRESTORE
chmod 600 /var/lib/eve-net/host-dns-emergency-restore.txt || true
echo "$SNAPSHOT_PATH" > /var/lib/eve-net/host-dns-last-runtime-snapshot

choose_nm_connection() {
  nmcli -t -f NAME,UUID,TYPE,DEVICE connection show --active \
    | awk -F: '$4 != "lo" && $3 != "loopback" {print $1; exit}'
}

host_dns_ok() {
  resolvectl query -t A example.com >/dev/null 2>&1 && getent ahostsv4 example.com >/dev/null 2>&1
}

rollback_now() {
  local code="$1"
  echo "host DNS validation failed; restoring runtime DNS snapshot..." >&2
  bash scripts/host-dns-runtime-restore.sh "$SNAPSHOT_PATH" || true
  if ! host_dns_ok; then
    echo "snapshot restore did not leave host DNS working; running runtime repair..." >&2
    bash scripts/host-dns-runtime-repair.sh "$CONFIG" || true
  fi
  if [[ "$LEGACY_REVERT" == "1" && ! host_dns_ok ]]; then
    echo "WARNING: legacy revert is unsafe on Fedora/systemd-resolved/NetworkManager/Amnezia setups" >&2
    bash scripts/host-dns-rollback.sh --legacy-revert "$BACKUP_DIR" || true
  fi
  exit "$code"
}

if [[ "$METHOD" == "auto" ]]; then
  if command -v resolvectl >/dev/null 2>&1 && [[ -d /sys/class/net/wlo1 ]]; then
    METHOD="resolved"
  elif command -v nmcli >/dev/null 2>&1 && [[ -n "$(choose_nm_connection || true)" ]]; then
    METHOD="nm"
  elif [[ ! -L /etc/resolv.conf ]]; then
    METHOD="resolvconf"
  else
    echo "BLOCKED: no safe automatic method found" >&2
    echo "Detected symlinked /etc/resolv.conf and no usable NetworkManager connection." >&2
    echo "Use dry-run plan and apply manually, or specify method explicitly." >&2
    exit 1
  fi
fi

echo "method: $METHOD"

case "$METHOD" in
  resolved)
    echo "$BACKUP_DIR" > /var/lib/eve-net/host-dns-last-backup
    links=(wlo1)
    if [[ -d /sys/class/net/amn0 ]]; then
      links+=(amn0)
    fi
    for link in "${links[@]}"; do
      resolvectl dns "$link" 127.0.0.1 || rollback_now 2
      resolvectl domain "$link" '~.' || rollback_now 2
      resolvectl default-route "$link" yes || rollback_now 2
    done
    resolvectl flush-caches || true
    ;;
  nm)
    if ! command -v nmcli >/dev/null 2>&1; then
      echo "nmcli not found" >&2
      exit 1
    fi
    CONN="$(choose_nm_connection || true)"
    if [[ -z "${CONN:-}" ]]; then
      echo "no active non-loopback NetworkManager connection found" >&2
      exit 1
    fi
    echo "$CONN" > /var/lib/eve-net/host-dns-current-nm-connection
    echo "$BACKUP_DIR" > /var/lib/eve-net/host-dns-last-backup
    nmcli connection modify "$CONN" ipv4.ignore-auto-dns yes ipv4.dns "127.0.0.1" ipv6.ignore-auto-dns yes ipv6.dns ""
    nmcli connection up "$CONN" || rollback_now 2
    ;;
  resolvconf)
    if [[ -L /etc/resolv.conf ]]; then
      echo "refusing to overwrite symlinked /etc/resolv.conf" >&2
      exit 1
    fi
    echo "$BACKUP_DIR" > /var/lib/eve-net/host-dns-last-backup
    cat > /etc/resolv.conf <<'EOFRESOLV'
# Managed by eve-net host DNS integration
nameserver 127.0.0.1
options edns0 trust-ad
EOFRESOLV
    ;;
  *)
    echo "unknown method: $METHOD" >&2
    exit 1
    ;;
esac

sleep 2

# Validate direct proxy after the network profile was bounced.
python3 - <<'PYDNS' || rollback_now 2
import socket, struct, random, sys
server=("127.0.0.1",53)
domain="example.com"
tid=random.randint(0,65535)
q=struct.pack("!HHHHHH",tid,0x0100,1,0,0,0)
for part in domain.split('.'):
    q += bytes([len(part)]) + part.encode()
q += b"\x00" + struct.pack("!HH",1,1)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.settimeout(2)
s.sendto(q,server)
data,_=s.recvfrom(512)
rcode=data[3] & 0x0f
an=struct.unpack("!H",data[6:8])[0]
if rcode != 0 or an < 1:
    print(f"post-apply proxy canary FAIL rcode={rcode} answers={an}", file=sys.stderr)
    sys.exit(1)
print(f"post-apply proxy canary: PASS rcode={rcode} answers={an}")
PYDNS

if getent ahostsv4 example.com >/tmp/eve-net-host-dns-test.$$ 2>/dev/null; then
  echo "host DNS test: PASS"
  sed 's/^/  /' /tmp/eve-net-host-dns-test.$$ | head -5
  rm -f /tmp/eve-net-host-dns-test.$$
else
  rm -f /tmp/eve-net-host-dns-test.$$
  echo "host DNS test: FAIL" >&2
  rollback_now 2
fi

echo "applied host DNS integration"
echo "runtime snapshot: $SNAPSHOT_PATH"
echo "rollback: sudo bash scripts/host-dns-rollback.sh --snapshot $SNAPSHOT_PATH"
echo "repair: sudo bash scripts/host-dns-runtime-repair.sh $CONFIG"
