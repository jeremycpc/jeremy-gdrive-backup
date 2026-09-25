# jeremy-gdrive-backup

This script backs up Google Drive to an external disk with [rclone](https://rclone.org).

rclone downloads straight from Google to the external disk. The internal disk of the Mac holds no copy of the files.

## What the script does

1. It checks that rclone is installed and that the disk is connected.
2. It checks that rclone can reach Google Drive.
3. It stops if another backup is already running.
4. It shows a "Backup started" notification.
5. It downloads new and changed files into `current`. Changed files replace the old copy.
6. It moves files that you deleted from Drive into `archive`. It adds the backup date to each file name.
7. It writes a log file on the external disk.
8. It shows a "Safe to eject" notification, or an error notification.

The script keeps the Mac awake while it runs. Keep the lid open during a long backup.

## Result on the disk

```
/Volumes/<disk>/
└── drive-backup/
    ├── current/    exact copy of Google Drive
    ├── archive/    deleted files, for example notes-deleted-2026-09-25_140312.docx
    └── logs/       one log file per run
```

The script writes only inside `drive-backup`. Other folders on the disk stay untouched.

The date in an archived file name is the date of the backup that found the deletion. It is not the date that you deleted the file.

Google Docs, Sheets, and Slides download as `.docx`, `.xlsx`, and `.pptx` files.

## Things to know

- The script never deletes files from the disk. Delete old files from `archive` by hand in Finder.
- A renamed or moved file in Drive goes to `archive` under its old name. `current` gets the new name.
- Changed files keep no old copy. Use the version history in Google Drive to get an earlier version.
- Files from other apps, such as Lucidchart diagrams, cannot be backed up. Google Drive holds only a link to them. The log shows a notice for each one, and the backup continues. Export these files from the app itself.
- "Shared with me" files and shared drives are not part of the backup.

## One-time setup

### 1. Install rclone

```bash
brew install rclone
```

### 2. Create a Google client ID

1. Go to console.cloud.google.com. Create a project named `rclone`.
2. Go to **APIs & Services → Library**. Enable the **Google Drive API**.
3. Set up the **OAuth consent screen**. Select **External**. Add yourself as a test user.
4. Click **Publish app**. If you skip this step, Google stops the access every 7 days.
   Google then says "Your app requires verification." Ignore this, and do not submit the app for review. The access works without verification.
   Google needs a home page, a privacy policy, and terms of service first. The `docs/` folder holds these pages. GitHub Pages serves them at https://jeremycpc.github.io/jeremy-gdrive-backup/.
5. Go to **Credentials → Create credentials → OAuth client ID**. Select **Desktop app**.
6. Copy the client ID and the client secret.

### 3. Connect rclone to Google Drive

1. Run `rclone config`.
2. Create a new remote named `gdrive`, of type `drive`.
3. Paste the client ID and the client secret.
4. Select the **drive.readonly** scope. rclone can then never change your Drive.
5. Sign in to Google in the browser. Google shows "Google hasn't verified this app." Click **Advanced**, then **Go to rclone-backup (unsafe)**. Approve the access. The warning only means that Google has not reviewed the app.
6. Test the connection with `rclone lsd gdrive:`.

### 4. Set the disk name

Find the disk name:

```bash
ls /Volumes
```

Then change `DISK_NAME` at the top of `drive-backup.sh`. You can also set `DRIVE_BACKUP_DISK` in your shell instead.

### 5. Make the script runnable

```bash
chmod +x drive-backup.sh
```

## Usage

Back up the whole Drive:

```bash
./drive-backup.sh
```

Back up one folder only:

```bash
./drive-backup.sh "Photos"
```

Show what would change, but copy nothing:

```bash
./drive-backup.sh --dry-run
```

If a backup stops for any reason, run it again. rclone continues where it stopped.

## Tests

The tests run the real script. A local folder stands in for Google Drive, and a second folder stands in for the external disk. They need rclone, but no Google account, internet, or disk.

```bash
./test.sh
```

The tests check these points:

1. The script stops when the disk is not connected, when Drive cannot be reached, or when another backup is running.
2. The first run copies all files into `current`.
3. A changed file replaces the old copy, and nothing goes to `archive`.
4. A deleted file moves to `archive` with the date in its name.
5. Two deleted files with the same name both stay in `archive`.
6. Other folders on the disk never change.
7. `--dry-run` changes nothing.
8. A run for one folder changes only that folder.
9. After an error in step 1, step 2 does not run.

## Check the backup

This command compares every file on the disk with Google Drive:

```bash
rclone check gdrive: "/Volumes/<disk>/drive-backup/current" --one-way
```
