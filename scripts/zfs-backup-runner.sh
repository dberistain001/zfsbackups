#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${ZFSBACKUPS_BASE_DIR:-/var/zfsBackups}"
CONFIG_DIR="${BASE_DIR}/configurations"
WORKER="${BASE_DIR}/scripts/zfs-backup-worker.sh"
LOCK_DIR="${ZFSBACKUPS_LOCK_DIR:-/run/lock}"
GLOBAL_LOCK="${LOCK_DIR}/zfsBackups-runner.lock"

DRY_RUN=false
FORCE=false
SPECIFIC_CONFIG=""

usage() {
  cat <<USAGE
Usage: zfs-backup-runner.sh [--dry-run] [--force] [CONFIG_FILE]

Without CONFIG_FILE, every enabled *.conf file in ${CONFIG_DIR} is checked.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*"
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *)
      [[ -z "$SPECIFIC_CONFIG" ]] || { usage >&2; exit 2; }
      SPECIFIC_CONFIG="$1"
      ;;
  esac
  shift
done

[[ -x "$WORKER" ]] || { log "ERROR: Worker not executable: $WORKER"; exit 1; }
mkdir -p -- "$CONFIG_DIR" "$LOCK_DIR"

exec 9>"$GLOBAL_LOCK"
if ! flock -n 9; then
  log "SKIP: Another runner instance is active"
  exit 0
fi

worker_args=()
[[ "$DRY_RUN" == "true" ]] && worker_args+=(--dry-run)
[[ "$FORCE" == "true" ]] && worker_args+=(--force)

configs=()
if [[ -n "$SPECIFIC_CONFIG" ]]; then
  configs+=("$SPECIFIC_CONFIG")
else
  while IFS= read -r -d '' file; do
    configs+=("$file")
  done < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.conf' -print0 | sort -z)
fi

if (( ${#configs[@]} == 0 )); then
  log "No configuration files found in $CONFIG_DIR"
  exit 0
fi

failures=0
for config in "${configs[@]}"; do
  log "Checking $config"
  if ! "$WORKER" "${worker_args[@]}" "$config"; then
    ((failures += 1))
  fi
done

if (( failures > 0 )); then
  log "Finished with $failures failed configuration(s)"
  exit 1
fi

log "Finished successfully"
