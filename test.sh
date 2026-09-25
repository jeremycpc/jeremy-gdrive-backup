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

  mkdir -p "$SRC/Photos" "$SRC/Docs" "$DISK/photos" "$STUBS"
  print "beach" > "$SRC/Photos/beach.jpg"
  print "notes v1" > "$SRC/Docs/notes.docx"
  print "budget" > "$SRC/budget.csv"

  # Other files on the disk that the backup must never touch.
  print "mine" > "$DISK/photos/keep.jpg"
  print "top" > "$DISK/top-level.txt"

  # Stand-ins: no notifications, and caffeinate only runs the command.
  print '#!/bin/sh\nexit 0' > "$STUBS/osascript"
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
  PATH="$STUBS:$PATH" \
  DRIVE_BACKUP_REMOTE="${REMOTE_OVERRIDE:-$SRC/}" \
  DRIVE_BACKUP_VOLUMES="$VOLS" \
  DRIVE_BACKUP_DISK="${DISK_OVERRIDE:-TestDisk}" \
  DRIVE_BACKUP_LOCK="$TMP/lock" \
    "$SCRIPT" "$@" > "$OUT" 2>&1
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
  assert_count "$BASE/logs" 1
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
  local attempts=$(cat "$BASE"/logs/*.log | grep -c "Attempt 3/3 failed")
  [[ $attempts -eq 1 ]] || fail "step 2 ran after step 1 failed ($attempts rclone commands failed)"
  # The deleted file must stay in current, because step 2 did not run.
  assert_content "$BASE/current/budget.csv" "budget"
  assert_count "$BASE/archive" 0
  assert_no_path "$TMP/lock"
}

# ---------------------------------------------------------------------------

for t in ${(ok)functions[(I)test_*]}; do
  run_test $t
done

print "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
