#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME="zfs-backup-worker"
BASE_DIR="${ZFSBACKUPS_BASE_DIR:-/var/zfsBackups}"
LOG_DIR="${BASE_DIR}/logs"
STATE_DIR="${BASE_DIR}/state"
LOCK_DIR="${ZFSBACKUPS_LOCK_DIR:-/run/lock}"
ZFS_BIN="${ZFS_BIN:-$(command -v zfs || true)}"

DRY_RUN=false
FORCE=false
CONFIG_FILE=""
LOG_FILE=""

usage() {
  cat <<USAGE
Usage: ${PROGRAM_NAME} [--dry-run] [--force] CONFIG_FILE

  --dry-run  Show snapshot and retention actions without changing ZFS or state.
  --force    Ignore INTERVAL_MINUTES and run immediately.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*"
}

fatal() {
  log "ERROR: $*"
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

strip_quotes() {
  local value="$1"
  if [[ ${#value} -ge 2 ]]; then
    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi
  printf '%s' "$value"
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_bool() {
  [[ "$1" == "true" || "$1" == "false" ]]
}

safe_name() {
  local value="$1"
  value="${value//\//-}"
  value="$(printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '-')"
  value="${value#-}"
  value="${value%-}"
  printf '%s' "${value:-dataset}"
}

# Defaults. Every config file may override these values.
ENABLED="true"
NAME=""
SOURCE=""
INTERVAL_MINUTES="60"
DAILY_KEEP="7"
WEEKLY_KEEP="4"
MONTHLY_KEEP="12"
RECURSIVE="false"
SNAPSHOT_PREFIX="zfsbackup"

parse_config() {
  local file="$1" line key value lineno=0
  [[ -r "$file" ]] || fatal "Cannot read configuration: $file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((lineno += 1))
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    if [[ ! "$line" =~ ^([A-Z_][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      fatal "Invalid syntax in $file at line $lineno"
    fi

    key="${BASH_REMATCH[1]}"
    value="$(trim "${BASH_REMATCH[2]}")"
    value="$(strip_quotes "$value")"

    case "$key" in
      ENABLED|NAME|SOURCE|INTERVAL_MINUTES|DAILY_KEEP|WEEKLY_KEEP|MONTHLY_KEEP|RECURSIVE|SNAPSHOT_PREFIX)
        printf -v "$key" '%s' "$value"
        ;;
      *)
        fatal "Unknown key '$key' in $file at line $lineno"
        ;;
    esac
  done < "$file"
}

validate_config() {
  is_bool "$ENABLED" || fatal "ENABLED must be true or false"
  [[ -n "$SOURCE" ]] || fatal "SOURCE is required"
  is_uint "$INTERVAL_MINUTES" || fatal "INTERVAL_MINUTES must be a whole number"
  (( INTERVAL_MINUTES >= 1 )) || fatal "INTERVAL_MINUTES must be at least 1"
  is_uint "$DAILY_KEEP" || fatal "DAILY_KEEP must be zero or a whole number"
  is_uint "$WEEKLY_KEEP" || fatal "WEEKLY_KEEP must be zero or a whole number"
  is_uint "$MONTHLY_KEEP" || fatal "MONTHLY_KEEP must be zero or a whole number"
  is_bool "$RECURSIVE" || fatal "RECURSIVE must be true or false"
  [[ "$SNAPSHOT_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || \
    fatal "SNAPSHOT_PREFIX contains unsupported characters"
}

resolve_dataset() {
  local source="$1" dataset=""

  # OpenZFS accepts a dataset name and, on supported versions, an absolute path.
  dataset="$($ZFS_BIN list -H -o name "$source" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$dataset" && "$dataset" != *@* ]]; then
    printf '%s' "$dataset"
    return 0
  fi

  # Portable fallback: compare SOURCE to each filesystem's mountpoint.
  if [[ "$source" == /* ]]; then
    source="${source%/}"
    while IFS=$'\t' read -r candidate mountpoint; do
      mountpoint="${mountpoint%/}"
      if [[ "$mountpoint" == "$source" ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    done < <($ZFS_BIN list -H -t filesystem -o name,mountpoint)
  fi

  return 1
}

latest_managed_snapshot_epoch() {
  local dataset="$1" prefix="$2" snap epoch latest=0
  while IFS=$'\t' read -r snap epoch; do
    [[ "$snap" == "${dataset}@${prefix}-"* ]] || continue
    is_uint "$epoch" || continue
    (( epoch > latest )) && latest="$epoch"
  done < <($ZFS_BIN list -H -p -t snapshot -o name,creation -r "$dataset" 2>/dev/null || true)
  printf '%s' "$latest"
}

read_last_success() {
  local state_file="$1" value="0"
  if [[ -r "$state_file" ]]; then
    IFS= read -r value < "$state_file" || value="0"
  fi
  is_uint "$value" || value="0"
  printf '%s' "$value"
}

write_last_success() {
  local state_file="$1" epoch="$2" tmp
  tmp="${state_file}.tmp.$$"
  umask 077
  printf '%s\n' "$epoch" > "$tmp"
  mv -f -- "$tmp" "$state_file"
}

retention_plan() {
  local dataset="$1" prefix="$2" now="$3"
  local today_start daily_cutoff weekly_cutoff monthly_cutoff weekly_stamp
  local snap epoch short date_key week_key month_key
  local destroy_failures=0 kept=0 removed=0
  declare -A keep_snapshot=()
  declare -A daily_seen=()
  declare -A weekly_seen=()
  declare -A monthly_seen=()
  local -a snapshots=()

  today_start="$(date -d 'today 00:00:00' +%s)"
  daily_cutoff="$(date -d "${DAILY_KEEP} days ago 00:00:00" +%s)"
  weekly_cutoff=$(( daily_cutoff - WEEKLY_KEEP * 7 * 86400 ))
  weekly_stamp="$(date -d "@${weekly_cutoff}" '+%Y-%m-%d %H:%M:%S')"
  if (( MONTHLY_KEEP > 0 )); then
    monthly_cutoff="$(date -d "${weekly_stamp} ${MONTHLY_KEEP} months ago" +%s)"
  else
    monthly_cutoff="$weekly_cutoff"
  fi

  while IFS=$'\t' read -r snap epoch; do
    [[ "$snap" == "${dataset}@${prefix}-"* ]] || continue
    is_uint "$epoch" || continue
    snapshots+=("${epoch}"$'\t'"${snap}")
  done < <($ZFS_BIN list -H -p -t snapshot -o name,creation -r "$dataset" 2>/dev/null | sort -t$'\t' -k2,2nr)

  log "Retention windows: today=all; daily=${DAILY_KEEP}; weekly=${WEEKLY_KEEP}; monthly=${MONTHLY_KEEP}"
  log "Managed snapshots found: ${#snapshots[@]}"

  # Select snapshots to retain. The newest snapshot in each period wins because
  # snapshots are sorted from newest to oldest.
  for short in "${snapshots[@]}"; do
    IFS=$'\t' read -r epoch snap <<< "$short"

    if (( epoch >= today_start )); then
      keep_snapshot["$snap"]="frequent-today"
      continue
    fi

    if (( DAILY_KEEP > 0 && epoch >= daily_cutoff )); then
      date_key="$(date -d "@${epoch}" '+%Y-%m-%d')"
      if [[ -z "${daily_seen[$date_key]+x}" ]]; then
        daily_seen["$date_key"]=1
        keep_snapshot["$snap"]="daily:${date_key}"
      fi
      continue
    fi

    if (( WEEKLY_KEEP > 0 && epoch >= weekly_cutoff )); then
      week_key="$(date -d "@${epoch}" '+%G-W%V')"
      if [[ -z "${weekly_seen[$week_key]+x}" ]]; then
        weekly_seen["$week_key"]=1
        keep_snapshot["$snap"]="weekly:${week_key}"
      fi
      continue
    fi

    if (( MONTHLY_KEEP > 0 && epoch >= monthly_cutoff )); then
      month_key="$(date -d "@${epoch}" '+%Y-%m')"
      if [[ -z "${monthly_seen[$month_key]+x}" ]]; then
        monthly_seen["$month_key"]=1
        keep_snapshot["$snap"]="monthly:${month_key}"
      fi
    fi
  done

  for short in "${snapshots[@]}"; do
    IFS=$'\t' read -r epoch snap <<< "$short"
    if [[ -n "${keep_snapshot[$snap]+x}" ]]; then
      ((kept += 1))
      log "KEEP    $snap (${keep_snapshot[$snap]})"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      ((removed += 1))
      log "DRY-RUN DESTROY $snap"
      continue
    fi

    local -a destroy_cmd=("$ZFS_BIN" destroy)
    [[ "$RECURSIVE" == "true" ]] && destroy_cmd+=(-r)
    destroy_cmd+=("$snap")

    if "${destroy_cmd[@]}"; then
      ((removed += 1))
      log "DESTROY $snap"
    else
      ((destroy_failures += 1))
      log "WARNING: Could not destroy $snap; it may be held, cloned, or busy"
    fi
  done

  log "Retention result: kept=${kept} destroyed=${removed} failures=${destroy_failures}"
  (( destroy_failures == 0 ))
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) usage >&2; exit 2 ;;
    *)
      [[ -z "$CONFIG_FILE" ]] || { usage >&2; exit 2; }
      CONFIG_FILE="$1"
      ;;
  esac
  shift
done

[[ -n "$CONFIG_FILE" ]] || { usage >&2; exit 2; }
[[ -n "$ZFS_BIN" && -x "$ZFS_BIN" ]] || fatal "The zfs command was not found"
[[ "${ZFSBACKUPS_ALLOW_NONROOT:-false}" == "true" || "$(id -u)" -eq 0 ]] || fatal "Run as root"

mkdir -p -- "$LOG_DIR" "$STATE_DIR" "$LOCK_DIR"
parse_config "$CONFIG_FILE"
validate_config

CONFIG_ID="$(safe_name "$(basename "$CONFIG_FILE" .conf)")"
DISPLAY_NAME="$(safe_name "${NAME:-$CONFIG_ID}")"

if [[ "$ENABLED" != "true" ]]; then
  log "SKIP: $CONFIG_FILE is disabled"
  exit 0
fi

DATASET="$(resolve_dataset "$SOURCE" || true)"
[[ -n "$DATASET" ]] || fatal "Could not resolve SOURCE '$SOURCE' to a ZFS dataset"

STATE_FILE="${STATE_DIR}/${CONFIG_ID}.last_success"
LOCK_FILE="${LOCK_DIR}/zfsBackups-${CONFIG_ID}.lock"
exec 8>"$LOCK_FILE"
if ! flock -n 8; then
  log "SKIP: Another run is active for $CONFIG_ID"
  exit 0
fi

NOW="$(date +%s)"
LAST_SUCCESS="$(read_last_success "$STATE_FILE")"
if (( LAST_SUCCESS == 0 )); then
  LAST_SUCCESS="$(latest_managed_snapshot_epoch "$DATASET" "$SNAPSHOT_PREFIX")"
fi
NEXT_DUE=$(( LAST_SUCCESS + INTERVAL_MINUTES * 60 ))

if [[ "$FORCE" != "true" && "$LAST_SUCCESS" -gt 0 && "$NOW" -lt "$NEXT_DUE" ]]; then
  log "SKIP: $DISPLAY_NAME is not due until $(date -d "@${NEXT_DUE}" '+%Y-%m-%d %H:%M:%S %z')"
  exit 0
fi

PLAIN_DATE="$(date '+%Y%m%d%H%M%S')"
LOG_FILE="${LOG_DIR}/${DISPLAY_NAME}-${NOW}-${PLAIN_DATE}.log"
touch "$LOG_FILE"
chmod 0640 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log "BEGIN config=$CONFIG_FILE"
log "Dataset=$DATASET source=$SOURCE interval=${INTERVAL_MINUTES}m recursive=$RECURSIVE dry_run=$DRY_RUN"
log "Log=$LOG_FILE"

SNAP_TIME="$(date '+%Y%m%dT%H%M%S')"
SNAP_SHORT="${SNAPSHOT_PREFIX}-${SNAP_TIME}"
SNAP_FULL="${DATASET}@${SNAP_SHORT}"

if "$ZFS_BIN" list -H -t snapshot -o name -- "$SNAP_FULL" >/dev/null 2>&1; then
  SNAP_SHORT="${SNAPSHOT_PREFIX}-${SNAP_TIME}-${NOW}"
  SNAP_FULL="${DATASET}@${SNAP_SHORT}"
fi

snapshot_ok=false
if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY-RUN SNAPSHOT $SNAP_FULL"
  snapshot_ok=true
else
  snapshot_cmd=("$ZFS_BIN" snapshot)
  [[ "$RECURSIVE" == "true" ]] && snapshot_cmd+=(-r)
  snapshot_cmd+=("$SNAP_FULL")

  log "CREATE  $SNAP_FULL"
  if "${snapshot_cmd[@]}"; then
    snapshot_ok=true
    write_last_success "$STATE_FILE" "$NOW"
    log "Snapshot created successfully"
  else
    fatal "Snapshot creation failed"
  fi
fi

retention_ok=true
if ! retention_plan "$DATASET" "$SNAPSHOT_PREFIX" "$NOW"; then
  retention_ok=false
fi

ln -sfn -- "$(basename "$LOG_FILE")" "${LOG_DIR}/${DISPLAY_NAME}-latest.log"

if [[ "$snapshot_ok" == "true" && "$retention_ok" == "true" ]]; then
  log "SUCCESS"
  exit 0
fi

log "COMPLETED WITH WARNINGS"
exit 1
