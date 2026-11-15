# jeremy-gdrive-backup

This script backs up Google Drive to the external disk `jeremy-backup` with [rclone](https://rclone.org).

rclone downloads straight from Google to the disk. The Mac's internal disk holds no copy. rclone has read-only access, so it can never change your Drive.

## Rules

### Where files go

```
/Volumes/jeremy-backup/
└── drive-backup/
    ├── current/   exact copy of Google Drive
    └── archive/   files deleted from Drive
```

The script writes only inside `drive-backup`. Other folders on the disk never change.

The logs stay on the Mac, in `~/Library/Logs/drive-backup/`. macOS lets rclone write to the disk, but not the script itself.

### What each change in Drive does

| In Google Drive, you… | Result on the disk |
|---|---|
| Add a file | It goes into `current` |
| Change a file | The new version replaces the old one in `current`. No old copy is kept |
| Rename a file, or move it to another folder | It is renamed or moved in `current`. Nothing goes to `archive` |
| Delete a file, or move it to the Trash | It moves from `current` to `archive` |
| Delete a folder | Every file in it moves to `archive` |

Two exceptions send a renamed file to `archive` under its old name:

1. A renamed Google Doc, Sheet, or Slides file. These have no checksum, so rclone cannot match them.
2. A file that you rename **and** change before the next backup.

### Archived file names

```
archive/<folder path>/<name>-deleted-<YYYY-MM-DD>_<HHMMSS>.<extension>
```

For example, `notes.docx` becomes `notes-deleted-2026-10-06_201445.docx`.

- The time is when the backup started, in local time. It is not when you deleted the file.
- The extension stays at the end, so the file still opens normally.
- The script never deletes anything from `archive`. Delete old files by hand in Finder.

### What the backup does not include

- Google Docs, Sheets, and Slides download as `.docx`, `.xlsx`, and `.pptx`.
- Files from other apps, such as Lucidchart, cannot be downloaded. Export them from the app itself.
- "Shared with me" files and shared drives are not included.
- Google Photos is separate from Drive. Use Google Takeout for it.
- Two files with the same name in one folder: rclone copies only one. Rename them in Drive.

## Run a backup

### By hand

1. Connect the disk.
2. Run one of these commands:

   ```bash
   cd ~/work/jeremy-gdrive-backup
   ./drive-backup.sh                    # whole Drive
   ./drive-backup.sh "Folder/Subfolder" # one folder only
   ./drive-backup.sh --dry-run          # show what would change, copy nothing
   ```

3. Keep the lid open. Wait for the "Safe to eject" notification.
4. Eject the disk in Finder.

If a backup stops for any reason, run it again. It continues where it stopped.

The first backup copies everything, about 19 GB. Later backups copy only new and changed files.

### Automatically when the disk is connected

1. Install the launchd job once:

   ```bash
   ./install.sh "jeremy-backup"
   ```

2. Connect the disk. A prompt asks "Back up Google Drive to jeremy-backup now?"
3. Click one of the three buttons:
   - **Back up** runs the backup in the background.
   - **Back up and show progress** runs the backup, and opens a Terminal window that shows its progress.
   - **Cancel** does nothing. No answer in 60 seconds also means Cancel.

The prompt appears at most once in 12 hours. To back up again sooner, run the script by hand. To remove the job, run `./install.sh --uninstall`.

The first time, macOS asks for access to the removable disk. Click **Allow**. Notifications appear under **Script Editor** in System Settings.

### Watch the progress

Run this at any time:

```bash
./progress.sh
```

- If a backup is running, it shows the progress until the backup ends. Then it says "The backup has finished."
- If no backup is running, it shows the end of the last log.

It shows the current step, each finished file, and any errors. While data moves, it shows a progress line every 10 seconds:

```
20:51:10    6.2 GiB / 19.3 GiB, 32%, 9.8 MiB/s, ETA 22m
```

While rclone only compares files, it shows "Checking files...", then "Still checking files (N min)" once a minute. Each step compares all files first, which takes about 1 minute.

After you rename or move files in Drive, it also shows "Matching renamed files...". rclone then reads those files on the disk to find them by checksum. This can take a few minutes, and nothing downloads during it.

Press `Ctrl+C` to stop watching. This does not stop the backup.

A backup that you start by hand in Terminal shows its own live progress. You do not need `progress.sh` for it.

### Check the backup

```bash
rclone check gdrive: "/Volumes/jeremy-backup/drive-backup/current" --one-way
```

This compares every file on the disk with Google Drive.

### Logs

All logs are on the Mac:

- `~/Library/Logs/drive-backup/<date>_<time>.log` is the detailed log of each backup.
- `~/Library/Logs/drive-backup/last-asked-jeremy-backup` records when the prompt last appeared.
- `~/Library/Logs/drive-backup.log` is the short log of the automatic job.

## One-time setup

This setup is already done on this Mac. Repeat it only on a new Mac.

1. Install rclone: `brew install rclone`.
2. In the Google Cloud Console, create a project. Enable the **Google Drive API**.
3. Set up the OAuth consent screen as **External**.
4. Under **Branding**, add the pages from this repository. GitHub Pages serves them from `docs/`:
   - Home page: https://jeremycpc.github.io/jeremy-gdrive-backup/
   - Privacy policy: https://jeremycpc.github.io/jeremy-gdrive-backup/privacy.html
   - Terms of service: https://jeremycpc.github.io/jeremy-gdrive-backup/terms.html
   - Authorized domain: `jeremycpc.github.io`
5. Under **Audience**, click **Publish app**. Without this, access expires every 7 days. Ignore the message "Your app requires verification."
6. Create an OAuth client of type **Desktop app**. Copy the client ID and secret.
7. Run `rclone config`. Create a remote named `gdrive`, type `drive`, with the **drive.readonly** scope.
8. In the browser, Google shows "Google hasn't verified this app." Click **Advanced**, then **Go to rclone-backup (unsafe)**.
9. Test it with `rclone lsd gdrive:`. Then delete the downloaded client JSON file.

The access lasts until you remove it, or until it is unused for 6 months. To connect again, run `rclone config reconnect gdrive:`.

## Tests

```bash
./test.sh
```

The tests run the real script against local folders. They need no Google account, internet, or disk. They cover each rule above, the automatic prompt, the installer, and a Mac OS Extended disk image.
