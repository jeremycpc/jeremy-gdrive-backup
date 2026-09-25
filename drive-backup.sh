#!/bin/zsh
# Back up Google Drive to an external disk with rclone.
#
# Usage: drive-backup.sh                      (whole Drive)
#        drive-backup.sh "Photos"             (one folder only)
#        drive-backup.sh --dry-run [folder]   (show what would change, copy nothing)
#        drive-backup.sh --auto               (for launchd: ask first, see below)
#
# --auto is for the launchd job that runs when any disk mounts. In this mode:
#   - If the backup disk is not connected, the script stops with no message.
#   - If it asked in the last 12 hours, the script stops with no message.
#   - Otherwise it asks "Start the backup now?". No answer in 60 seconds means Skip.
#
# Result on the disk:
#   drive-backup/current/  exact copy of Google Drive
#   drive-backup/archive/  files deleted from Drive, renamed with the backup date
#   drive-backup/logs/     one log file per run

# Change DISK_NAME to your disk name, or set DRIVE_BACKUP_DISK in your shell.
DISK_NAME="${DRIVE_BACKUP_DISK:-MyDisk}"
# The other DRIVE_BACKUP_* settings exist for the tests. Normal use needs no change.
REMOTE="${DRIVE_BACKUP_REMOTE:-gdrive:}"
VOLUMES="${DRIVE_BACKUP_VOLUMES:-/Volumes}"
LOCK="${DRIVE_BACKUP_LOCK:-/tmp/drive-backup.lock}"
QUIET_HOURS="${DRIVE_BACKUP_QUIET_HOURS:-12}"
PROMPT_SECONDS="${DRIVE_BACKUP_PROMPT_SECONDS:-60}"

AUTO=0
DRY_RUN=()
while [[ "$1" == --* ]]; do
  case "$1" in
    --auto)    AUTO=1 ;;
    --dry-run) DRY_RUN=(--dry-run) ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

DISK="$VOLUMES/$DISK_NAME"
BASE="$DISK/drive-backup"
FOLDER="${1:-}"
STAMP=$(date +%Y-%m-%d_%H%M%S)
LOG_DIR="$BASE/logs"
LOG="$LOG_DIR/$STAMP.log"
LAST_ASKED="$BASE/.last-asked"

notify() {
  osascript -e "display notification \"$2\" with title \"$1\""
}

# Stop if rclone is not installed.
if ! command -v rclone >/dev/null 2>&1; then
  echo "rclone is not installed. Run: brew install rclone"
  exit 1
fi

# Stop if the disk is not connected.
# In --auto mode another disk started the job, so this is not an error.
if [[ ! -d "$DISK" ]]; then
  (( AUTO )) && exit 0
  echo "Disk $DISK_NAME is not connected."
  exit 1
fi

# In --auto mode, ask at most once per QUIET_HOURS. Other mounts (USB sticks,
# installers, Time Machine) start the job again while the disk is connected.
if (( AUTO )) && [[ -n "$(find "$LAST_ASKED" -mmin -$(( QUIET_HOURS * 60 )) 2>/dev/null)" ]]; then
  exit 0
fi

# Stop if another backup is running.
if ! mkdir "$LOCK" 2>/dev/null; then
  (( AUTO )) && exit 0
  echo "A backup is already running. If not, run: rmdir $LOCK"
  exit 1
fi
trap 'rmdir "$LOCK"' EXIT

# In --auto mode, ask before the backup starts.
if (( AUTO )); then
  mkdir -p "$BASE"
  touch "$LAST_ASKED"
  answer=$(osascript -e "display dialog \"Back up Google Drive to $DISK_NAME now?\" \
    with title \"Google Drive backup\" buttons {\"Skip\", \"Start\"} \
    default button \"Start\" giving up after $PROMPT_SECONDS" 2>/dev/null)
  if [[ "$answer" != *"button returned:Start"* || "$answer" == *"gave up:true"* ]]; then
    echo "$(date): backup skipped."
    exit 0
  fi
fi

# Stop if Google Drive cannot be reached.
if ! rclone lsd "$REMOTE" >/dev/null 2>&1; then
  notify "Drive backup failed" "Cannot reach Google Drive."
  echo "Cannot reach Google Drive. Check the internet, or run: rclone config reconnect $REMOTE"
  exit 1
fi

# Show live progress only in a Terminal. Under launchd it would fill the log.
PROGRESS=()
[[ -t 1 ]] && PROGRESS=(--progress)

mkdir -p "$BASE/current" "$BASE/archive" "$LOG_DIR"
notify "Drive backup started" "Do not eject $DISK_NAME."

# Step 1: download new and changed files. Changed files are replaced.
caffeinate -i rclone copy "$REMOTE$FOLDER" "$BASE/current/$FOLDER" \
  "${DRY_RUN[@]}" \
  --log-file "$LOG" --log-level INFO \
  "${PROGRESS[@]}"
STATUS=$?

# Step 2: move files deleted from Drive into the archive, with the date in the name.
# Only runs if step 1 had no errors. rclone also skips it if the Drive listing fails.
if [[ $STATUS -eq 0 ]]; then
  caffeinate -i rclone sync "$REMOTE$FOLDER" "$BASE/current/$FOLDER" \
    "${DRY_RUN[@]}" \
    --backup-dir "$BASE/archive/$FOLDER" \
    --suffix "-deleted-$STAMP" --suffix-keep-extension \
    --log-file "$LOG" --log-level INFO \
    "${PROGRESS[@]}"
  STATUS=$?
fi

if [[ $STATUS -eq 0 ]]; then
  notify "Drive backup complete" "Safe to eject $DISK_NAME."
else
  notify "Drive backup had errors" "Run it again to retry. Log: $STAMP.log"
fi
exit $STATUS
