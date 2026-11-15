#!/bin/zsh
# Tests for drive-backup.sh.
#
# A local folder stands in for Google Drive, and a second folder stands in for
# the external disk. The tests need rclone, but no Google account, internet, or disk.
#
# Usage: ./test.sh

SCRIPT="${0:A:h}/drive-backup.sh"
PASS=0
FAIL=0

if ! command -v rclone >/dev/null 2>&1; then
  echo "rclone is not installed. Run: brew install rclone"
  exit 1
fi

# Create a fresh sandbox for each test.
setup() {
  TMP=$(mktemp -d)
  SRC="$TMP/drive"                      # stands in for Google Drive
  VOLS="$TMP/Volumes"                   # stands in for /Volumes
  DISK="$VOLS/TestDisk"
  BASE="$DISK/drive-backup"
  STUBS="$TMP/stubs"
  LOGS="$TMP/mac-logs"                  # stands in for ~/Library/Logs/drive-backup
  MARKER="$LOGS/last-asked-TestDisk"

  mkdir -p "$SRC/Photos" "$SRC/Docs" "$DISK/photos" "$STUBS"
  print "beach" > "$SRC/Photos/beach.jpg"
  print "notes v1" > "$SRC/Docs/notes.docx"
  print "budget" > "$SRC/budget.csv"

  # Other files on the disk that the backup must never touch.
  print "mine" > "$DISK/photos/keep.jpg"
  print "top" > "$DISK/top-level.txt"

  # Stand-ins. osascript records each call in $CALLS and answers the prompt
  # with $DIALOG_ANSWER: Start (Back up), Progress (Back up and show progress),
  # Skip (Cancel), or anything else for no answer. open records its arguments.
  # caffeinate only runs the command.
  CALLS="$TMP/osascript-calls.txt"
  : > "$CALLS"
  cat > "$STUBS/osascript" <<'STUB'
#!/bin/sh
echo "$*" >> "$CALLS"
case "$*" in
  *"display dialog"*)
    case "$DIALOG_ANSWER" in
      Start)    echo "button returned:Back up, gave up:false" ;;
      Progress) echo "button returned:Back up and show progress, gave up:false" ;;
      Skip)     echo "execution error: User canceled. (-128)" >&2; exit 1 ;;
      *)     echo "button returned:, gave up:true" ;;
    esac ;;
esac
exit 0
STUB
  print '#!/bin/sh\nexit 0' > "$STUBS/launchctl"
  cat > "$STUBS/open" <<'STUB'
#!/bin/sh
echo "open $*" >> "$CALLS"
[ -s "$DRIVE_BACKUP_LOCK/log" ] && echo "lock-has-log $(cat "$DRIVE_BACKUP_LOCK/log")" >> "$CALLS"
exit 0
STUB
  print '#!/bin/sh\n[ "$1" = "-i" ] && shift\nexec "$@"' > "$STUBS/caffeinate"
  chmod +x "$STUBS"/*
}

teardown() {
  chmod -R u+rwx "$TMP" 2>/dev/null
  rm -rf "$TMP"
}

# Run the backup script against the sandbox. Output goes to $OUT.
run_backup() {
  OUT="$TMP/out.txt"
  PATH="$STUBS:$PATH" CALLS="$CALLS" DIALOG_ANSWER="${DIALOG_ANSWER:-}" \
  DRIVE_BACKUP_REMOTE="${REMOTE_OVERRIDE:-$SRC/}" \
  DRIVE_BACKUP_VOLUMES="$VOLS" \
  DRIVE_BACKUP_DISK="${DISK_OVERRIDE:-TestDisk}" \
  DRIVE_BACKUP_LOCK="$TMP/lock" DRIVE_BACKUP_LOG_DIR="$LOGS" \
    "$SCRIPT" "$@" > "$OUT" 2>&1
}

# Run progress.sh against the sandbox, with a 20-second limit, so a broken
# progress.sh fails the test and does not hang it. Output goes to $OUT.
run_progress() {
  OUT="$TMP/out.txt"
  ( DRIVE_BACKUP_LOG_DIR="$LOGS" DRIVE_BACKUP_LOCK="$TMP/lock" \
    DRIVE_BACKUP_PROGRESS_WAIT="${PROGRESS_WAIT:-10}" \
    exec "${SCRIPT:h}/progress.sh" ) > "$OUT" 2>&1 &
  local pid=$! n=0
  while kill -0 $pid 2>/dev/null; do
    if (( n++ >= 40 )); then
      pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null
      fail "progress.sh did not finish within 20 seconds"
      return 124
    fi
    sleep 0.5
  done
  wait $pid
}

# Assertions. Each one records a failure message but does not stop the test.
ERRORS=()
fail() { ERRORS+=("$1"); }
assert_status()  { [[ $1 -eq $2 ]] || fail "exit status was $1, expected $2"; }
assert_file()    { [[ -f "$1" ]] || fail "missing file: ${1#$TMP/}"; }
assert_no_path() { [[ ! -e "$1" ]] || fail "should not exist: ${1#$TMP/}"; }
assert_content() { [[ "$(cat "$1" 2>/dev/null)" == "$2" ]] || fail "wrong content in ${1#$TMP/}"; }
assert_count()   {
  local n=$(find "$1" -type f 2>/dev/null | wc -l | tr -d ' ')
  [[ $n -eq $2 ]] || fail "${1#$TMP/} has $n files, expected $2"
}
assert_output()  { grep -q "$1" "$OUT" || fail "output does not contain: $1"; }
assert_asked()     { grep -q "display dialog" "$CALLS" || fail "the prompt was not shown"; }
assert_not_asked() { ! grep -q "display dialog" "$CALLS" || fail "the prompt was shown"; }
asked_count()      { grep -c "display dialog" "$CALLS"; }
assert_silent() {
  [[ ! -s "$CALLS" ]] || fail "osascript was called: $(head -1 "$CALLS")"
  [[ ! -s "$OUT" ]] || fail "script printed output: $(head -1 "$OUT")"
}
assert_others_untouched() {
  assert_content "$DISK/photos/keep.jpg" "mine"
  assert_content "$DISK/top-level.txt" "top"
}

# Run one test function in a fresh sandbox and report the result.
run_test() {
  local name=$1
  ERRORS=()
  setup
  $name
  if (( ${#ERRORS} == 0 )); then
    print "PASS  $name"
    (( PASS++ ))
  else
    print "FAIL  $name"
    for e in "${ERRORS[@]}"; do print "      - $e"; done
    print "      output:"; sed 's/^/        /' "$OUT" 2>/dev/null | tail -8
    (( FAIL++ ))
  fi
  teardown
}

# ---------------------------------------------------------------------------

test_01_stops_when_disk_missing() {
  DISK_OVERRIDE=NoSuchDisk run_backup
  assert_status $? 1
  assert_output "is not connected"
  assert_no_path "$VOLS/NoSuchDisk"
  assert_no_path "$BASE"
}

test_02_stops_when_drive_unreachable() {
  REMOTE_OVERRIDE="$TMP/no-such-drive/" run_backup
  assert_status $? 1
  assert_output "Cannot reach Google Drive"
  assert_no_path "$BASE"
}

test_03_stops_when_backup_running() {
  mkdir "$TMP/lock"
  run_backup
  assert_status $? 1
  assert_output "already running"
  assert_no_path "$BASE"
}

test_04_first_run_copies_everything() {
  run_backup
  assert_status $? 0
  assert_content "$BASE/current/Photos/beach.jpg" "beach"
  assert_content "$BASE/current/Docs/notes.docx" "notes v1"
  assert_content "$BASE/current/budget.csv" "budget"
  assert_count "$BASE/archive" 0
  assert_count "$LOGS" 1
  assert_no_path "$TMP/lock"
  assert_others_untouched
}

test_05_changed_file_is_replaced_without_archive() {
  run_backup
  print "notes v2, longer" > "$SRC/Docs/notes.docx"
  run_backup
  assert_status $? 0
  assert_content "$BASE/current/Docs/notes.docx" "notes v2, longer"
  assert_count "$BASE/archive" 0
  assert_others_untouched
}

test_06_deleted_file_moves_to_archive_with_date() {
  run_backup
  rm "$SRC/Docs/notes.docx"
  run_backup
  assert_status $? 0
  assert_no_path "$BASE/current/Docs/notes.docx"
  local archived=("$BASE"/archive/Docs/notes-deleted-*.docx(N))
  (( ${#archived} == 1 )) || fail "expected 1 archived notes file, found ${#archived}"
  [[ "${archived[1]:t}" =~ '^notes-deleted-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.docx$' ]] \
    || fail "archived name has the wrong form: ${archived[1]:t}"
  assert_content "${archived[1]}" "notes v1"
  assert_content "$BASE/current/budget.csv" "budget"
  assert_others_untouched
}

test_06b_renamed_and_moved_files_update_current() {
  run_backup
  mv "$SRC/Docs/notes.docx" "$SRC/Docs/notes-final.docx"     # rename
  mkdir -p "$SRC/Archive2024"
  mv "$SRC/Photos/beach.jpg" "$SRC/Archive2024/beach.jpg"     # move to another folder
  sleep 1
  run_backup
  assert_status $? 0
  assert_content "$BASE/current/Docs/notes-final.docx" "notes v1"
  assert_content "$BASE/current/Archive2024/beach.jpg" "beach"
  assert_no_path "$BASE/current/Docs/notes.docx"
  assert_no_path "$BASE/current/Photos/beach.jpg"
  assert_count "$BASE/archive" 0
  local log=$(ls -t "$LOGS"/*.log | head -1)
  grep -q 'Renamed from' "$log" || fail "rclone did not rename on the disk"
  ! grep -qE 'notes-final.docx: Copied|beach.jpg: Copied' "$log" \
    || fail "a renamed file was downloaded again"
}

test_06c_renamed_and_changed_file_is_archived() {
  run_backup
  rm "$SRC/Docs/notes.docx"
  print "notes v2, longer" > "$SRC/Docs/notes-final.docx"   # new name and new content
  sleep 1
  run_backup
  assert_status $? 0
  assert_content "$BASE/current/Docs/notes-final.docx" "notes v2, longer"
  assert_no_path "$BASE/current/Docs/notes.docx"
  assert_count "$BASE/archive/Docs" 1
}

test_07_same_name_deleted_twice_keeps_both() {
  run_backup
  rm "$SRC/Docs/notes.docx"
  run_backup
  sleep 1   # the date in the name has one-second resolution
  print "notes second copy" > "$SRC/Docs/notes.docx"
  run_backup
  rm "$SRC/Docs/notes.docx"
  sleep 1
  run_backup
  assert_status $? 0
  assert_count "$BASE/archive/Docs" 2
  grep -rqx "notes v1" "$BASE/archive/Docs" 2>/dev/null || fail "first copy is missing from archive"
  grep -rqx "notes second copy" "$BASE/archive/Docs" 2>/dev/null || fail "second copy is missing from archive"
}

test_08_other_disk_folders_untouched_after_all_runs() {
  run_backup
  rm "$SRC/budget.csv"
  print "new" > "$SRC/new.txt"
  run_backup
  run_backup --dry-run
  run_backup "Photos"
  assert_others_untouched
  local top=$(ls "$DISK" | sort | tr '\n' ' ')
  [[ "$top" == "drive-backup photos top-level.txt " ]] || fail "disk top level changed: $top"
}

test_08b_finder_files_stay_out_of_archive() {
  run_backup
  print "finder" > "$BASE/current/Docs/.DS_Store"
  print "finder" > "$BASE/current/.DS_Store"
  sleep 1
  run_backup
  assert_status $? 0
  assert_count "$BASE/archive" 0
  assert_file "$BASE/current/Docs/.DS_Store"
}

test_09_dry_run_changes_nothing() {
  run_backup
  rm "$SRC/budget.csv"
  print "notes v2, longer" > "$SRC/Docs/notes.docx"
  print "new" > "$SRC/new.txt"
  run_backup --dry-run
  assert_status $? 0
  assert_content "$BASE/current/budget.csv" "budget"
  assert_content "$BASE/current/Docs/notes.docx" "notes v1"
  assert_no_path "$BASE/current/new.txt"
  assert_count "$BASE/archive" 0
}

test_10_one_folder_changes_only_that_folder() {
  run_backup
  rm "$SRC/Photos/beach.jpg"
  print "sunset" > "$SRC/Photos/sunset.jpg"
  rm "$SRC/Docs/notes.docx"
  print "new" > "$SRC/new.txt"
  run_backup "Photos"
  assert_status $? 0
  assert_content "$BASE/current/Photos/sunset.jpg" "sunset"
  assert_no_path "$BASE/current/Photos/beach.jpg"
  assert_count "$BASE/archive/Photos" 1
  # Changes outside Photos are left for the next full run.
  assert_content "$BASE/current/Docs/notes.docx" "notes v1"
  assert_no_path "$BASE/current/new.txt"
  assert_no_path "$BASE/archive/Docs"
}

test_11_step_two_skipped_when_step_one_fails() {
  run_backup
  rm "$SRC/budget.csv"
  print "locked" > "$SRC/Docs/locked.txt"
  chmod 000 "$SRC/Docs/locked.txt"
  run_backup
  local code=$?
  (( code != 0 )) || fail "exit status was 0, expected an error"
  # rclone retries each command 3 times. One "Attempt 3/3" line means only step 1 ran.
  # (rclone sync also refuses to move files after read errors, so the checks
  # below pass even without the script's own guard. This line tests the guard.)
  local attempts=$(cat "$LOGS"/*.log | grep -c "Attempt 3/3 failed")
  [[ $attempts -eq 1 ]] || fail "step 2 ran after step 1 failed ($attempts rclone commands failed)"
  # The deleted file must stay in current, because step 2 did not run.
  assert_content "$BASE/current/budget.csv" "budget"
  assert_count "$BASE/archive" 0
  assert_no_path "$TMP/lock"
}

test_12_auto_stops_silently_when_disk_missing() {
  DISK_OVERRIDE=NoSuchDisk run_backup --auto
  assert_status $? 0
  assert_silent
  assert_no_path "$VOLS/NoSuchDisk"
}

test_13_auto_start_runs_backup() {
  DIALOG_ANSWER=Start run_backup --auto
  assert_status $? 0
  assert_asked
  assert_content "$BASE/current/budget.csv" "budget"
  grep -q "Safe to eject" "$CALLS" || fail "no 'Safe to eject' notification"
  ! grep -q "Transferred:" "$OUT" || fail "live progress went to the launchd log"
  ! grep -q "^open " "$CALLS" || fail "Terminal opened, but only Back up was clicked"
  local log=$(ls -t "$LOGS"/*.log | head -1)
  grep -q "^=== Step 1 of 2" "$log" || fail "log has no step 1 marker"
  grep -q "^=== Step 2 of 2" "$log" || fail "log has no step 2 marker"
  grep -q "^=== Backup complete" "$log" || fail "log has no end marker"
  grep -qE 'INFO  : +[0-9.]+ [KMGT]?i?B / [0-9.]+ [KMGT]?i?B, [0-9-]+%?.*ETA' "$log" \
    || fail "log has no one-line progress for progress.sh"
  assert_file "$MARKER"
  assert_no_path "$TMP/lock"
  assert_others_untouched
}

test_13b_auto_progress_opens_terminal() {
  DIALOG_ANSWER=Progress run_backup --auto
  assert_status $? 0
  assert_asked
  assert_content "$BASE/current/budget.csv" "budget"
  grep -q "^open -a Terminal ${SCRIPT:h}/progress.sh$" "$CALLS" \
    || fail "Terminal did not open progress.sh"
  local log=$(ls -t "$LOGS"/*.log | head -1)
  grep -q "^=== Backup started" "$log" || fail "log has no start marker"
  grep -qx "lock-has-log $log" "$CALLS" || fail "Terminal opened before the log path was in the lock"
  (( $(ls "$LOGS"/*.log | wc -l) == 1 )) || fail "expected one log file"
}

test_14_auto_skip_does_not_back_up() {
  DIALOG_ANSWER=Skip run_backup --auto
  assert_status $? 0
  assert_asked
  assert_no_path "$BASE/current"
  assert_no_path "$TMP/lock"
}

test_15_auto_no_answer_does_not_back_up() {
  DIALOG_ANSWER=none run_backup --auto
  assert_status $? 0
  assert_asked
  assert_no_path "$BASE/current"
}

test_16_auto_asks_once_in_quiet_period() {
  DIALOG_ANSWER=Skip run_backup --auto
  : > "$CALLS"
  DIALOG_ANSWER=Start run_backup --auto
  assert_status $? 0
  assert_silent
  assert_no_path "$BASE/current"
}

test_17_auto_asks_again_after_quiet_period() {
  DIALOG_ANSWER=Skip run_backup --auto
  touch -t 202001010000 "$MARKER"   # pretend it asked long ago
  : > "$CALLS"
  DIALOG_ANSWER=Start run_backup --auto
  assert_status $? 0
  (( $(asked_count) == 1 )) || fail "expected 1 prompt, got $(asked_count)"
  assert_content "$BASE/current/budget.csv" "budget"
}

test_17b_script_writes_nothing_on_the_disk_itself() {
  # macOS blocks this script (zsh) from writing to removable disks. Only rclone
  # may write there. So logs and the marker must be on the Mac.
  DIALOG_ANSWER=Start run_backup --auto
  assert_status $? 0
  [[ "$(ls -A "$BASE")" == "current" ]] || fail "disk has more than current: $(ls -A "$BASE" | tr '\n' ' ')"
  assert_file "$MARKER"
  assert_count "$LOGS" 2    # one log and the marker
}

test_17c_skipped_prompt_leaves_no_log() {
  DIALOG_ANSWER=Skip run_backup --auto
  assert_file "$MARKER"
  assert_count "$LOGS" 1    # only the marker
}

test_18_auto_stops_silently_when_backup_running() {
  mkdir "$TMP/lock"
  DIALOG_ANSWER=Start run_backup --auto
  assert_status $? 0
  assert_silent
  assert_no_path "$BASE/current"
}

test_19_manual_run_never_asks() {
  DIALOG_ANSWER=Skip run_backup
  assert_status $? 0
  assert_not_asked
  assert_content "$BASE/current/budget.csv" "budget"
  DIALOG_ANSWER=Skip run_backup
  assert_not_asked
}

test_19b_progress_shows_last_log_when_idle() {
  run_backup
  run_progress
  assert_status $? 0
  assert_output "No backup is running"
  assert_output "=== Backup complete"
  assert_output "budget.csv: Copied"
}

test_19c_progress_follows_the_running_backups_log() {
  # An older log is newer on disk than the running backup's log. progress.sh
  # must use the path in the lock, not the newest file.
  local log="$LOGS/2026-01-01_000000.log" old="$LOGS/2026-01-01_000001.log"
  mkdir -p "$LOGS" "$TMP/lock"
  print "=== Step 1 of 2: new files" > "$log"
  print "2026/01/01 00:00:00 INFO  : OLD-BACKUP.pdf: Copied (new)" > "$old"
  print -r -- "$log" > "$TMP/lock/log"
  ( sleep 2
    print "2026/01/01 00:00:05 INFO  :    1 GiB / 2 GiB, 50%, 10 MiB/s, ETA 1m" >> "$log"
    print "2026/01/01 00:00:06 DEBUG : noise" >> "$log"
    print "=== Backup complete" >> "$log"
    sleep 1; rm -f "$TMP/lock/log"; rmdir "$TMP/lock" ) &
  run_progress
  assert_status $? 0
  wait
  assert_output "=== Step 1 of 2"
  assert_output "50%, 10 MiB/s, ETA 1m"
  assert_output "=== Backup complete"
  assert_output "The backup has finished"
  ! grep -q "noise" "$OUT" || fail "progress shows debug lines"
  ! grep -q "OLD-BACKUP" "$OUT" || fail "progress shows an old log"
  ! pgrep -f "tail -n \+1 -F $log" >/dev/null || fail "tail is still running"
}

test_19d_progress_never_shows_old_log_without_lock_path() {
  mkdir -p "$LOGS" "$TMP/lock"
  print "2026/01/01 00:00:00 INFO  : OLD-BACKUP.pdf: Copied (new)" > "$LOGS/old.log"
  PROGRESS_WAIT=1 run_progress
  assert_status $? 1
  assert_output "waiting for an answer to its prompt"
  ! grep -q "OLD-BACKUP" "$OUT" || fail "progress shows an old log"
}

test_19e_progress_shows_checking_once_instead_of_repeats() {
  mkdir -p "$LOGS"
  { print "=== Step 1 of 2: new files"
    for i in 1 2 3; do print "2026/01/01 00:00:0$i INFO  :          0 B / 0 B, -, 0 B/s, ETA -"; done
    print "2026/01/01 00:00:04 INFO  :    1 MiB / 2 MiB, 50%, 1 MiB/s, ETA 1s"
    print "2026/01/01 00:00:05 INFO  : a.pdf: Copied (new)"
    for i in 6 7 8; do print "2026/01/01 00:00:0$i INFO  :    2 MiB / 2 MiB, 100%, 0 B/s, ETA -"; done
    print "=== Backup complete"
  } > "$LOGS/a.log"
  run_progress
  assert_status $? 0
  (( $(grep -c "0 B / 0 B" "$OUT") == 0 )) || fail "progress shows 0 B / 0 B lines"
  (( $(grep -c "2 MiB / 2 MiB" "$OUT") == 1 )) || fail "progress repeats the same line"
  # One "Checking files" for the 0 B lines, one for the repeated 100% lines.
  (( $(grep -c "Checking files" "$OUT") == 2 )) || fail "expected 2 Checking files lines, got $(grep -c "Checking files" "$OUT")"
  assert_output "1 MiB / 2 MiB, 50%"
  assert_output "a.pdf: Copied"
}

test_20_install_writes_valid_job() {
  local home="$TMP/home"
  OUT="$TMP/out.txt"
  HOME="$home" PATH="$STUBS:$PATH" "${SCRIPT:h}/install.sh" "My Disk" > "$OUT" 2>&1
  assert_status $? 0
  local job="$home/Library/LaunchAgents/com.jeremy.drive-backup.plist"
  assert_file "$job"
  plutil -lint -s "$job" || fail "job file is not a valid plist"
  [[ "$(plutil -extract EnvironmentVariables.DRIVE_BACKUP_DISK raw "$job")" == "My Disk" ]] \
    || fail "wrong disk name in job file"
  [[ "$(plutil -extract ProgramArguments.0 raw "$job")" == "$SCRIPT" ]] \
    || fail "wrong script path in job file"
  [[ "$(plutil -extract ProgramArguments.1 raw "$job")" == "--auto" ]] \
    || fail "job does not use --auto"
  [[ "$(plutil -extract StartOnMount raw "$job")" == "true" ]] \
    || fail "job does not start on mount"
  HOME="$home" PATH="$STUBS:$PATH" "${SCRIPT:h}/install.sh" --uninstall > "$OUT" 2>&1
  assert_no_path "$job"
}

test_21_second_run_on_hfs_disk_changes_nothing() {
  # Google Drive keeps file times in milliseconds. Mac OS Extended keeps
  # seconds. A real HFS+ disk image checks that the second run sees no change.
  local img="$TMP/hfs.dmg" mnt="$VOLS/HfsDisk"
  hdiutil create -quiet -size 20m -fs HFS+ -volname HfsDisk "$img" \
    || { fail "could not create HFS+ image"; return; }
  mkdir -p "$mnt"
  hdiutil attach -quiet -nobrowse -mountpoint "$mnt" "$img" \
    || { fail "could not mount HFS+ image"; return; }
  touch -d 2025-07-29T09:50:25.607 "$SRC/budget.csv" "$SRC/Docs/notes.docx"

  DISK_OVERRIDE=HfsDisk run_backup
  sleep 1   # each run gets its own log file, named to the second
  DISK_OVERRIDE=HfsDisk run_backup
  assert_status $? 0
  local log=$(ls -t "$LOGS"/*.log | head -1)
  ! grep -qE "Copied|Updated modification time" "$log" \
    || fail "second run changed files: $(grep -E 'Copied|Updated' "$log" | head -1)"
  assert_count "$mnt/drive-backup/archive" 0

  hdiutil detach -quiet "$mnt"
}

# ---------------------------------------------------------------------------

for t in ${(ok)functions[(I)test_*]}; do
  run_test $t
done

print "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
