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
#   - Otherwise it asks "Back up Google Drive now?" with three buttons:
#     Cancel, Back up, and Back up and show progress. The last one opens
#     progress.sh in a Terminal window. No answer in 60 seconds means Cancel.
#
# Result on the disk:
#   drive-backup/current/  exact copy of Google Drive
#   drive-backup/archive/  files deleted from Drive, renamed with the backup date
#                          (renamed and moved files are renamed in current instead)
#   drive-backup/logs/     one log file per run

# Change DISK_NAME to your disk name, or set DRIVE_BACKUP_DISK in your shell.
DISK_NAME="${DRIVE_BACKUP_DISK:-jeremy-backup}"
# The other DRIVE_BACKUP_* settings exist for the tests. Normal use needs no change.
REMOTE="${DRIVE_BACKUP_REMOTE:-gdrive:}"
VOLUMES="${DRIVE_BACKUP_VOLUMES:-/Volumes}"
LOCK="${DRIVE_BACKUP_LOCK:-/tmp/drive-backup.lock}"
QUIET_HOURS="${DRIVE_BACKUP_QUIET_HOURS:-12}"
PROMPT_SECONDS="${DRIVE_BACKUP_PROMPT_SECONDS:-60}"
SCRIPT_DIR="${0:A:h}"

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
  mkdir -p "$BASE" 2>/dev/null
  touch "$LAST_ASKED" 2>/dev/null
  # A button named "Cancel" makes osascript fail with no output. That also skips.
  answer=$(osascript -e "display dialog \"Back up Google Drive to $DISK_NAME now?\" \
    with title \"Google Drive backup\" \
    buttons {\"Cancel\", \"Back up\", \"Back up and show progress\"} \
    default button \"Back up\" giving up after $PROMPT_SECONDS" 2>/dev/null)
  # macOS can block the first write to the disk until you allow access in its
  # own prompt. So write the marker again after the answer.
  mkdir -p "$BASE" 2>/dev/null
  touch "$LAST_ASKED" 2>/dev/null || echo "$(date): could not write $LAST_ASKED"
  choice="${${answer#button returned:}%%, gave up:*}"
  if [[ "$answer" == *"gave up:true"* || ( "$choice" != "Back up" && "$choice" != "Back up and show progress" ) ]]; then
    echo "$(date): backup skipped."
    exit 0
  fi
  if [[ "$choice" == "Back up and show progress" ]]; then
    # Create the log first, so progress.sh finds this backup's log.
    mkdir -p "$LOG_DIR" 2>/dev/null
    print "=== Backup started $(date)" >> "$LOG"
    open -a Terminal "$SCRIPT_DIR/progress.sh"
  fi
fi

# Stop if Google Drive cannot be reached.
if ! rclone lsd "$REMOTE" >/dev/null 2>&1; then
  notify "Drive backup failed" "Cannot reach Google Drive."
  echo "Cannot reach Google Drive. Check the internet, or run: rclone config reconnect $REMOTE"
  exit 1
fi

# Mac OS Extended (HFS+) and exFAT disks store file times to the second, but
# Google Drive uses milliseconds. Without --modify-window every file looks
# changed on every run, and Google Docs (which have no checksum) download again.
TIME_WINDOW=(--modify-window 1s)

# Finder creates .DS_Store in each folder you open. Ignore them, so step 2
# does not move them into the archive.
IGNORE=(--exclude .DS_Store)

# In a Terminal, show live progress. Otherwise write one progress line to the
# log every 10 seconds, for progress.sh.
if [[ -t 1 ]]; then
  PROGRESS=(--progress)
else
  PROGRESS=(--stats 10s --stats-one-line)
fi

mkdir -p "$BASE/current" "$BASE/archive" "$LOG_DIR"
notify "Drive backup started" "Do not eject $DISK_NAME."
print "=== Step 1 of 2: new, renamed, moved, and deleted files" >> "$LOG"

# Step 1: follow renames and moves, download new files, archive deleted files.
# --track-renames finds a file with the same checksum under a new name or folder,
#   and renames the copy on the disk. (Google Docs have no checksum, so a renamed
#   Doc still goes to the archive and downloads again under the new name.)
# --ignore-existing leaves files that exist on both sides for step 2.
# rclone does not archive anything if the Drive listing has errors.
caffeinate -i rclone sync "$REMOTE$FOLDER" "$BASE/current/$FOLDER" \
  "${DRY_RUN[@]}" \
  --track-renames --ignore-existing \
  --backup-dir "$BASE/archive/$FOLDER" \
  --suffix "-deleted-$STAMP" --suffix-keep-extension \
  "${TIME_WINDOW[@]}" "${IGNORE[@]}" \
  --log-file "$LOG" --log-level INFO \
  "${PROGRESS[@]}"
STATUS=$?

# Step 2: download changed files. They replace the old copy, with no archive copy.
# Only runs if step 1 had no errors.
if [[ $STATUS -eq 0 ]]; then
  print "=== Step 2 of 2: changed files" >> "$LOG"
  caffeinate -i rclone copy "$REMOTE$FOLDER" "$BASE/current/$FOLDER" \
    "${DRY_RUN[@]}" \
    "${TIME_WINDOW[@]}" "${IGNORE[@]}" \
    --log-file "$LOG" --log-level INFO \
    "${PROGRESS[@]}"
  STATUS=$?
fi

if [[ $STATUS -eq 0 ]]; then
  print "=== Backup complete $(date). Safe to eject $DISK_NAME." >> "$LOG"
  notify "Drive backup complete" "Safe to eject $DISK_NAME."
else
  print "=== Backup had errors $(date). Run it again to retry." >> "$LOG"
  notify "Drive backup had errors" "Run it again to retry. Log: $STAMP.log"
fi
exit $STATUS
