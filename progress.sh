#!/bin/zsh
# Show the progress of the backup.
#
# Usage: progress.sh
#
# If a backup is running, it follows that backup's log until the backup ends.
# If no backup is running, it shows the end of the last log.
# The backup prompt opens this script in Terminal when you click
# "Back up and show progress".

LOG_DIR="${DRIVE_BACKUP_LOG_DIR:-$HOME/Library/Logs/drive-backup}"
LOCK="${DRIVE_BACKUP_LOCK:-/tmp/drive-backup.lock}"
WAIT_SECONDS="${DRIVE_BACKUP_PROGRESS_WAIT:-10}"

# Show the lines that matter: steps, progress, finished files, and errors.
# rclone writes a progress line every 10 seconds. While it only checks files,
# the line does not change, so show "Checking files..." once instead.
show() {
  awk '
    function clean(s) { sub(/^[0-9]+\/[0-9]+\/[0-9]+ /, "", s); sub(/ (INFO|NOTICE) +: +/, "  ", s); return s }
    /^=== / { print; checking = 0; last = ""; fflush(); next }
    / ETA / {
      key = $0; sub(/^[0-9\/]+ [0-9:]+ /, "", key)
      if (key ~ / 0 B \/ 0 B/ || key == last) {
        if (!checking) { print "Checking files..."; checking = 1; fflush() }
        next
      }
      checking = 0; last = key; print clean($0); fflush(); next
    }
    /Copied|Renamed from|Moved into backup dir|ERROR|There was nothing to transfer/ {
      checking = 0; print clean($0); fflush()
    }'
}

# A running backup records its log path in the lock.
if [[ -d "$LOCK" ]]; then
  for (( i = 0; i < WAIT_SECONDS * 2; i++ )); do
    [[ -s "$LOCK/log" || ! -d "$LOCK" ]] && break
    sleep 0.5
  done
  LOG=$(cat "$LOCK/log" 2>/dev/null)
  if [[ -d "$LOCK" && -z "$LOG" ]]; then
    echo "A backup is waiting for an answer to its prompt, or its log path is missing."
    echo "If no backup is running, run: rm -f $LOCK/log; rmdir $LOCK"
    exit 1
  fi
fi

if [[ -n "$LOG" ]]; then
  echo "Log: $LOG"
  echo
  # Follow the log until the backup releases its lock.
  tail -n +1 -F "$LOG" 2>/dev/null | show &
  while [[ -d "$LOCK" ]]; do
    sleep 2
  done
  sleep 1
  pkill -P $$ tail 2>/dev/null
  kill %1 2>/dev/null
  echo
  echo "The backup has finished. You can close this window."
  exit 0
fi

LOG=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -1)
if [[ -z "$LOG" ]]; then
  echo "No backup log found in $LOG_DIR."
  exit 1
fi
echo "Log: $LOG"
echo
echo "No backup is running. The end of the last log:"
echo
show < "$LOG" | tail -n 15
