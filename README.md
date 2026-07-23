# zfsBackups

A small, configuration-driven Bash snapshot manager for OpenZFS on Linux.
It creates snapshots at a per-dataset interval, applies daily/weekly/monthly
retention, and writes one detailed log for every due backup run.

> Important: ZFS snapshots stored in the same pool are recovery points, not an
> independent backup. Disk/pool loss destroys both the live data and these
> snapshots. A later version can add `zfs send`/`zfs receive` to another pool or
> host for a true second copy.

## Installed layout

```text
/var/zfsBackups/
├── configurations/    # one root-owned .conf file per dataset
├── logs/              # NAME-EPOCH-YYYYMMDDHHMMSS.log
├── scripts/
│   ├── zfs-backup-runner.sh
│   └── zfs-backup-worker.sh
├── scipts -> scripts  # compatibility for the requested misspelling
├── state/             # last successful snapshot epoch per config
└── README.md
```

## Install

```bash
unzip zfsBackups.zip
cd zfsBackups
sudo ./install.sh
```

The installer enables `zfs-backups.timer`. It wakes once per minute. The runner
reads every `*.conf` file and only starts a snapshot when that file's
`INTERVAL_MINUTES` has elapsed.

## Add a dataset

```bash
sudo cp /var/zfsBackups/configurations/example.conf \
  /var/zfsBackups/configurations/documents.conf
sudo nano /var/zfsBackups/configurations/documents.conf
sudo chmod 600 /var/zfsBackups/configurations/documents.conf
```

Example:

```ini
ENABLED=true
NAME=documents
SOURCE=tank/home/documents
INTERVAL_MINUTES=30
DAILY_KEEP=7
WEEKLY_KEEP=8
MONTHLY_KEEP=12
RECURSIVE=false
SNAPSHOT_PREFIX=zfsbackup
```

`SOURCE` should preferably be the real ZFS dataset name (`pool/dataset`). An
exact mountpoint such as `/home/zfs/newdataset` is also resolved automatically.
Confirm both columns with:

```bash
zfs list -H -o name,mountpoint
```

## Retention behavior

For a configuration with snapshots every 15 minutes and `7/8/12` retention:

1. All managed snapshots from the current calendar day are kept.
2. For the previous 7 days, the newest snapshot from each day is kept.
3. For the preceding 8 weeks, the newest snapshot from each ISO week is kept.
4. For the preceding 12 months, the newest snapshot from each month is kept.
5. Everything older or redundant is deleted, but only when its snapshot name
   starts with the configured `SNAPSHOT_PREFIX-`.

This means unrelated/manual snapshots are never touched.

## Test and operate

Dry-run every config immediately:

```bash
sudo zfs-backups --dry-run --force
```

Run every config immediately:

```bash
sudo zfs-backups --force
```

Run one config:

```bash
sudo zfs-backups --force /var/zfsBackups/configurations/documents.conf
```

Check scheduling and recent output:

```bash
systemctl status zfs-backups.timer
systemctl list-timers zfs-backups.timer
journalctl -u zfs-backups.service -n 100 --no-pager
```

Logs:

```bash
ls -lh /var/zfsBackups/logs/
tail -n 100 /var/zfsBackups/logs/documents-latest.log
```

## Safety details

- Config files are parsed as data; they are not `source`d or executed.
- A global lock prevents overlapping timer runs, and each dataset has its own
  lock for manual execution.
- State is updated only after snapshot creation succeeds.
- Retention only targets snapshots matching the configured prefix.
- A snapshot that has a ZFS hold, a dependent clone, or another destroy blocker
  remains in place and is reported as a warning.
- Use a unique prefix per independent snapshot policy on the same dataset.

## Restoring

List snapshots:

```bash
zfs list -t snapshot -o name,creation -s creation tank/home/documents
```

Browse a filesystem snapshot when `.zfs/snapshot` is visible:

```bash
ls /mountpoint/.zfs/snapshot/
```

Use `zfs rollback` only after understanding that it discards newer filesystem
changes. Copying individual files out of `.zfs/snapshot/...` is often safer.
