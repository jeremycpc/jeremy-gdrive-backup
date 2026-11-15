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
# the line does not change. Then show "Checking files..." once, and
# "Still checking files (N min)" each full minute after that.
show() {
  awk '
    function clean(s) { sub(/^[0-9]+\/[0-9]+\/[0-9]+ /, "", s); sub(/ (INFO|NOTICE) +: +/, "  ", s); return s }
    function secs(s,   t) { split(substr(s, 12, 8), t, ":"); return t[1] * 3600 + t[2] * 60 + t[3] }
    function out(s) { print s; fflush() }
    function check_tick() {
      if (!checking) { out("Checking files..."); checking = 1; since = secs($0); shown = 0; return }
      mins = int((secs($0) - since + 86400) % 86400 / 60)
      if (mins > shown) { shown = mins; out(substr($0, 12, 8) "  Still checking files (" mins " min)") }
    }
    /^=== / { out($0); checking = 0; last = ""; next }
    /Making map for --track-renames/ { out(substr($0, 12, 8) "  Matching renamed files..."); next }
    /Finished making map for --track-renames/ { out(substr($0, 12, 8) "  Finished matching renamed files."); next }
    / ETA / {
      key = $0; sub(/^[0-9\/]+ [0-9:]+ /, "", key)
      if (key ~ / 0 B \/ 0 B/ || key == last) { check_tick(); next }
      checking = 0; last = key; out(clean($0)); next
    }
    /Copied|Renamed from|Moved into backup dir|ERROR|There was nothing to transfer/ {
      checking = 0; out(clean($0))
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
