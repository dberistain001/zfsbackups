#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/base/configurations" "$TMP/base/logs" "$TMP/base/state" "$TMP/locks"

cat > "$TMP/bin/zfs" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
DB="${FAKE_ZFS_DB:?}"
cmd="$1"; shift
case "$cmd" in
  list)
    joined=" $* "
    if [[ "$joined" == *" -t snapshot "* ]]; then
      if [[ "$joined" == *" tank/test@"* ]]; then
        target="${!#}"
        grep -q "^${target}"$'\t' "$DB" && printf '%s\n' "$target"
      else
        cat "$DB"
      fi
    elif [[ "${!#}" == "tank/test" || "${!#}" == "/mnt/test" ]]; then
      printf 'tank/test\n'
    else
      printf 'tank/test\t/mnt/test\n'
    fi
    ;;
  snapshot)
    target="${!#}"
    printf '%s\t%s\n' "$target" "$(date +%s)" >> "$DB"
    ;;
  destroy)
    target="${!#}"
    grep -v -F "${target}"$'\t' "$DB" > "$DB.tmp" || true
    mv "$DB.tmp" "$DB"
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$TMP/bin/zfs"

cat > "$TMP/base/configurations/test.conf" <<'CONF'
ENABLED=true
NAME=test
SOURCE=/mnt/test
INTERVAL_MINUTES=15
DAILY_KEEP=2
WEEKLY_KEEP=2
MONTHLY_KEEP=2
RECURSIVE=false
SNAPSHOT_PREFIX=zfsbackup
CONF

DB="$TMP/snapshots.tsv"
: > "$DB"
for spec in \
  '0 hours ago' \
  '1 hours ago' \
  '1 days ago' \
  '1 days ago 1 hour' \
  '2 days ago' \
  '4 days ago' \
  '10 days ago' \
  '20 days ago' \
  '2 months ago' \
  '3 months ago' \
  '8 months ago'; do
  epoch="$(date -d "$spec" +%s)"
  stamp="$(date -d "@$epoch" '+%Y%m%dT%H%M%S')"
  printf 'tank/test@zfsbackup-%s\t%s\n' "$stamp" "$epoch" >> "$DB"
done
printf 'tank/test@manual-never-delete\t%s\n' "$(date -d '2 years ago' +%s)" >> "$DB"

export FAKE_ZFS_DB="$DB"
export ZFS_BIN="$TMP/bin/zfs"
export ZFSBACKUPS_BASE_DIR="$TMP/base"
export ZFSBACKUPS_LOCK_DIR="$TMP/locks"
export ZFSBACKUPS_ALLOW_NONROOT=true

"$ROOT/scripts/zfs-backup-worker.sh" --dry-run --force "$TMP/base/configurations/test.conf" >/dev/null
"$ROOT/scripts/zfs-backup-worker.sh" --force "$TMP/base/configurations/test.conf" >/dev/null

grep -q '^tank/test@manual-never-delete' "$DB"
managed_count="$(grep -c '^tank/test@zfsbackup-' "$DB" || true)"
(( managed_count >= 1 ))

echo "PASS: retention kept managed recovery points and did not delete manual snapshots"
