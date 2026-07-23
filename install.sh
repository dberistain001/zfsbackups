#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Run this installer as root." >&2; exit 1; }
command -v zfs >/dev/null 2>&1 || { echo "OpenZFS is not installed or zfs is not in PATH." >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "flock is required (normally provided by util-linux)." >&2; exit 1; }

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEST=/var/zfsBackups

install -d -m 0755 "$DEST" "$DEST/scripts" "$DEST/logs"
install -d -m 0700 "$DEST/configurations" "$DEST/state"
install -m 0755 "$SOURCE_DIR/scripts/zfs-backup-runner.sh" "$DEST/scripts/"
install -m 0755 "$SOURCE_DIR/scripts/zfs-backup-worker.sh" "$DEST/scripts/"
install -m 0644 "$SOURCE_DIR/README.md" "$DEST/README.md"

if [[ ! -e "$DEST/configurations/example.conf" ]]; then
  install -m 0600 "$SOURCE_DIR/configurations/example.conf" "$DEST/configurations/example.conf"
fi

# The requested path contained "scipts". Keep a compatibility symlink while
# using the correctly spelled scripts directory internally.
if [[ ! -e "$DEST/scipts" && ! -L "$DEST/scipts" ]]; then
  ln -s scripts "$DEST/scipts"
fi

install -m 0644 "$SOURCE_DIR/systemd/zfs-backups.service" /etc/systemd/system/zfs-backups.service
install -m 0644 "$SOURCE_DIR/systemd/zfs-backups.timer" /etc/systemd/system/zfs-backups.timer
ln -sfn "$DEST/scripts/zfs-backup-runner.sh" /usr/local/sbin/zfs-backups

systemctl daemon-reload
systemctl enable --now zfs-backups.timer

echo
echo "Installed in $DEST"
echo "1. Copy and edit $DEST/configurations/example.conf"
echo "2. Test: zfs-backups --dry-run --force"
echo "3. Run:  zfs-backups --force"
echo "4. Status: systemctl status zfs-backups.timer"
