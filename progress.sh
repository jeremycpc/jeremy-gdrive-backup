#!/bin/zsh
# Show the progress of the backup.
#
# Usage: progress.sh
#
# If a backup is running, it follows that backup's log until the backup ends.
# If no backup is running, it shows the end of the last log.
# The backup prompt opens this script in Terminal when you click
# "Back up and show progress".

DISK_NAME="${DRIVE_BACKUP_DISK:-jeremy-backup}"
VOLUMES="${DRIVE_BACKUP_VOLUMES:-/Volumes}"
LOCK="${DRIVE_BACKUP_LOCK:-/tmp/drive-backup.lock}"
LOG_DIR="$VOLUMES/$DISK_NAME/drive-backup/logs"

# Show the lines that matter: steps, progress, finished files, and errors.
show() {
  grep --line-buffered -E '^=== |ETA|Copied|Renamed from|Moved into backup dir|ERROR' \
    | sed -u -E 's/^[0-9]{4}\/[0-9]{2}\/[0-9]{2} //; s/ (INFO|NOTICE)  ?: / /'
}

latest_log() { ls -t "$LOG_DIR"/*.log 2>/dev/null | head -1; }

LOG=$(latest_log)
if [[ -z "$LOG" ]]; then
  echo "No backup log found in $LOG_DIR. Is the disk connected?"
  exit 1
fi

echo "Log: $LOG"
echo

if [[ ! -d "$LOCK" ]]; then
  echo "No backup is running. The end of the last log:"
  echo
  tail -n 400 "$LOG" | show | tail -n 15
  exit 0
fi

# Follow the log until the backup releases its lock.
tail -n +1 -F "$LOG" 2>/dev/null | show &
TAIL_PID=$!
while [[ -d "$LOCK" ]]; do
  sleep 2
done
sleep 1
kill $TAIL_PID 2>/dev/null
pkill -P $$ tail 2>/dev/null
echo
echo "The backup has finished. You can close this window."
