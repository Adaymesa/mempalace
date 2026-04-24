#!/bin/bash
# MemPalace iCloud Backup — runs daily via launchd.
# Compresses ~/.mempalace/ to iCloud Drive, keeps last $KEEP backups per host.
# Filenames are namespaced by hostname so multiple Macs sharing the same
# iCloud account don't overwrite or evict each other's backups.

BACKUP_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/mempalace"
SOURCE_DIR="$HOME/.mempalace"
LOG_FILE="$SOURCE_DIR/backup.log"
KEEP=3

# Slugify hostname: keep alnum/_/-, collapse runs, trim ends.
# "Aday Mesa" -> "Aday-Mesa".
HOST="$(hostname -s | tr -c '[:alnum:]_-' '-' | tr -s '-' | sed 's/^-//;s/-$//')"
if [ -z "$HOST" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup FAILED (empty hostname)" >> "$LOG_FILE"
    exit 1
fi

mkdir -p "$BACKUP_DIR"

FILENAME="mempalace_backup_${HOST}_$(date +%Y%m%d_%H%M).tar.gz"
tar -czf "$BACKUP_DIR/$FILENAME" -C "$HOME" .mempalace/ 2>/dev/null
TAR_STATUS=$?

if [ $TAR_STATUS -eq 0 ]; then
    # Per-host retention: glob restricts cleanup to THIS host's backups,
    # so other Macs sharing the iCloud folder are unaffected.
    ( cd "$BACKUP_DIR" && ls -1 "mempalace_backup_${HOST}_"*.tar.gz 2>/dev/null \
        | sort -r \
        | tail -n +$((KEEP + 1)) \
        | xargs rm -f )
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup complete: $FILENAME" >> "$LOG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup FAILED (tar exit $TAR_STATUS)" >> "$LOG_FILE"
    exit 1
fi
