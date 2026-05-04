#!/bin/bash
# MemPalace iCloud Backup — runs daily via launchd.
# Compresses ~/.mempalace/ to iCloud Drive, keeps last $KEEP backups per host.
# Filenames are namespaced by hostname so multiple Macs sharing the same
# iCloud account don't overwrite or evict each other's backups.
#
# Integrity gate (added 2026-05-02):
#   Before tarring, run `PRAGMA integrity_check` on chroma.sqlite3. If the
#   DB reports anything other than "ok", the resulting backup is tagged
#   `.CORRUPT.tar.gz` and a separate alert is logged so a corrupt DB cannot
#   silently roll out across the retention window.
#   Clean backups are also pinned to `_pinned/last_known_good.tar.gz` so a
#   verified-clean snapshot survives independent of $KEEP retention.

BACKUP_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/mempalace"
PINNED_DIR="$BACKUP_DIR/_pinned"
SOURCE_DIR="$HOME/.mempalace"
LOG_FILE="$SOURCE_DIR/backup.log"
ALERT_FILE="$SOURCE_DIR/backup_alerts.log"
CHROMA_DB="$SOURCE_DIR/palace/chroma.sqlite3"
# Two weeks of daily snapshots gives a real recovery window — the previous
# value (3) collapsed too fast to catch slow-burn corruption.
KEEP=14

# Slugify hostname: keep alnum/_/-, collapse runs, trim ends.
# "Aday Mesa" -> "Aday-Mesa".
HOST="$(hostname -s | tr -c '[:alnum:]_-' '-' | tr -s '-' | sed 's/^-//;s/-$//')"
if [ -z "$HOST" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup FAILED (empty hostname)" >> "$LOG_FILE"
    exit 1
fi

mkdir -p "$BACKUP_DIR" "$PINNED_DIR"

# ---- Integrity gate ----
INTEGRITY_RESULT=""
DB_TAG=""
if [ -f "$CHROMA_DB" ]; then
    # PRAGMA integrity_check is read-only and cooperates with WAL mode, so
    # it's safe even if MCP servers are mid-write. Capture stderr too in
    # case sqlite3 itself complains about the file.
    INTEGRITY_RESULT="$(sqlite3 "$CHROMA_DB" 'PRAGMA integrity_check;' 2>&1 | head -50)"
    if [ "$INTEGRITY_RESULT" != "ok" ]; then
        DB_TAG=".CORRUPT"
        {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] CORRUPTION detected in $CHROMA_DB"
            echo "    integrity_check output (first 50 lines):"
            echo "$INTEGRITY_RESULT" | sed 's/^/      /'
            echo "    Backup will be tagged with .CORRUPT suffix."
            echo "----"
        } >> "$ALERT_FILE"
        # Best-effort macOS notification so the operator notices same-day.
        if command -v osascript >/dev/null 2>&1; then
            osascript -e 'display notification "Backup detected DB corruption — see ~/.mempalace/backup_alerts.log" with title "MemPalace" sound name "Basso"' >/dev/null 2>&1 || true
        fi
    fi
else
    INTEGRITY_RESULT="(chroma.sqlite3 not found — fresh palace?)"
fi

# ---- Tar the snapshot ----
FILENAME="mempalace_backup_${HOST}_$(date +%Y%m%d_%H%M)${DB_TAG}.tar.gz"
tar -czf "$BACKUP_DIR/$FILENAME" -C "$HOME" .mempalace/ 2>/dev/null
TAR_STATUS=$?

if [ $TAR_STATUS -eq 0 ]; then
    # Per-host retention: glob restricts cleanup to THIS host's backups,
    # so other Macs sharing the iCloud folder are unaffected. Both clean
    # and .CORRUPT backups count toward retention together — corruption
    # tagging is the signal, not a separate retention pool.
    ( cd "$BACKUP_DIR" && ls -1 "mempalace_backup_${HOST}_"*.tar.gz 2>/dev/null \
        | sort -r \
        | tail -n +$((KEEP + 1)) \
        | xargs rm -f )

    if [ -z "$DB_TAG" ]; then
        # Pin clean backups so the most recent verified snapshot survives
        # KEEP rotation even when the next N days produce only corrupt ones.
        cp -p "$BACKUP_DIR/$FILENAME" "$PINNED_DIR/last_known_good.tar.gz" 2>/dev/null || true
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup complete: $FILENAME (integrity: ${INTEGRITY_RESULT:0:80})" >> "$LOG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup FAILED (tar exit $TAR_STATUS)" >> "$LOG_FILE"
    exit 1
fi
