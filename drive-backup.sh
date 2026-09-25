#!/bin/zsh
# Back up Google Drive to an external disk with rclone.
#
# Usage: drive-backup.sh                      (whole Drive)
#        drive-backup.sh "Photos"             (one folder only)
#        drive-backup.sh --dry-run [folder]   (show what would change, copy nothing)
#
# Result on the disk:
#   drive-backup/current/  exact copy of Google Drive
#   drive-backup/archive/  files deleted from Drive, renamed with the backup date
#   drive-backup/logs/     one log file per run

# Change DISK_NAME to your disk name, or set DRIVE_BACKUP_DISK in your shell.
DISK_NAME="${DRIVE_BACKUP_DISK:-MyDisk}"
REMOTE="gdrive:"

DRY_RUN=()
if [[ "$1" == "--dry-run" ]]; then
  DRY_RUN=(--dry-run)
  shift
fi

DISK="/Volumes/$DISK_NAME"
BASE="$DISK/drive-backup"
FOLDER="${1:-}"
STAMP=$(date +%Y-%m-%d_%H%M)
LOG_DIR="$BASE/logs"
LOG="$LOG_DIR/$STAMP.log"
LOCK="/tmp/drive-backup.lock"

notify() {
  osascript -e "display notification \"$2\" with title \"$1\""
}

# Stop if rclone is not installed.
if ! command -v rclone >/dev/null 2>&1; then
  echo "rclone is not installed. Run: brew install rclone"
  exit 1
fi

# Stop if the disk is not connected.
if [[ ! -d "$DISK" ]]; then
  echo "Disk $DISK_NAME is not connected."
  exit 1
fi

# Stop if Google Drive cannot be reached.
if ! rclone lsd "$REMOTE" >/dev/null 2>&1; then
  notify "Drive backup failed" "Cannot reach Google Drive."
  echo "Cannot reach Google Drive. Check the internet, or run: rclone config reconnect $REMOTE"
  exit 1
fi

# Stop if another backup is running.
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "A backup is already running. If not, run: rmdir $LOCK"
  exit 1
fi
trap 'rmdir "$LOCK"' EXIT

mkdir -p "$BASE/current" "$BASE/archive" "$LOG_DIR"
notify "Drive backup started" "Do not eject $DISK_NAME."

# Step 1: download new and changed files. Changed files are replaced.
caffeinate -i rclone copy "$REMOTE$FOLDER" "$BASE/current/$FOLDER" \
  "${DRY_RUN[@]}" \
  --log-file "$LOG" --log-level INFO \
  --progress
STATUS=$?

# Step 2: move files deleted from Drive into the archive, with the date in the name.
# Only runs if step 1 had no errors. rclone also skips it if the Drive listing fails.
if [[ $STATUS -eq 0 ]]; then
  caffeinate -i rclone sync "$REMOTE$FOLDER" "$BASE/current/$FOLDER" \
    "${DRY_RUN[@]}" \
    --backup-dir "$BASE/archive/$FOLDER" \
    --suffix "-deleted-$STAMP" --suffix-keep-extension \
    --log-file "$LOG" --log-level INFO \
    --progress
  STATUS=$?
fi

if [[ $STATUS -eq 0 ]]; then
  notify "Drive backup complete" "Safe to eject $DISK_NAME."
else
  notify "Drive backup had errors" "Run it again to retry. Log: $STAMP.log"
fi
exit $STATUS
