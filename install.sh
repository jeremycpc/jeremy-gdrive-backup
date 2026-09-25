#!/bin/zsh
# Install or remove the launchd job that offers a backup when the disk is connected.
#
# Usage: ./install.sh "DiskName"    (install, or update the disk name)
#        ./install.sh --uninstall   (remove)

LABEL="com.jeremy.drive-backup"
DIR="${0:A:h}"
TEMPLATE="$DIR/launchd/$LABEL.plist"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/drive-backup.log"
DOMAIN="gui/$(id -u)"

if [[ "$1" == "--uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
  rm -f "$TARGET"
  echo "Removed $LABEL."
  exit 0
fi

DISK_NAME="$1"
if [[ -z "$DISK_NAME" ]]; then
  echo "Usage: ./install.sh \"DiskName\"   (see: ls /Volumes)"
  exit 1
fi

mkdir -p "${TARGET:h}" "${LOG:h}"
sed -e "s|__SCRIPT__|$DIR/drive-backup.sh|" \
    -e "s|__DISK__|$DISK_NAME|" \
    -e "s|__LOG__|$LOG|" \
    "$TEMPLATE" > "$TARGET"
plutil -lint -s "$TARGET" || exit 1

# Reload, so a second install picks up a new disk name.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
launchctl bootstrap "$DOMAIN" "$TARGET" || exit 1

echo "Installed $LABEL for disk \"$DISK_NAME\"."
echo "Log: $LOG"
