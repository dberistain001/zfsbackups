#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
systemctl disable --now zfs-backups.timer 2>/dev/null || true
rm -f /etc/systemd/system/zfs-backups.timer /etc/systemd/system/zfs-backups.service
rm -f /usr/local/sbin/zfs-backups
systemctl daemon-reload
cat <<'MESSAGE'
The systemd units and command symlink were removed.
/var/zfsBackups was intentionally preserved so configs, state, and logs remain.
Remove it manually only after reviewing its contents.
MESSAGE
