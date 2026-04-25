#!/bin/bash
# mempal_sync.sh — bidirectional MemPalace sync via Cloudflare R2.
# Same script runs on every machine: pushes own snapshot, pulls every peer's,
# merges peer drawers into local Chroma. Idempotent — safe to run repeatedly.
#
# Required env (sourced from ~/.mempalace.sync.env if present):
#   MEMPAL_R2_REMOTE   rclone remote name (default: mempal_r2)
#   MEMPAL_R2_BUCKET   R2 bucket name (default: mempalace-sync)
#   MEMPAL_PYTHON      python with chromadb (default: auto-detect)
#
# Exit codes: 0 = success or skipped cleanly, 1 = configuration error,
# 2 = transport error (rclone). Logged to ~/.mempalace.sync.log.

set -u

ENV_FILE="$HOME/.mempalace.sync.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

R2_REMOTE="${MEMPAL_R2_REMOTE:-mempal_r2}"
R2_BUCKET="${MEMPAL_R2_BUCKET:-mempalace-sync}"
LOG_FILE="$HOME/.mempalace.sync.log"
SOURCE_DIR="$HOME/.mempalace"
WORK_DIR="$(mktemp -d -t mempal_sync.XXXXXX)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGE_SCRIPT="$SCRIPT_DIR/mempal_merge.py"

cleanup() { rm -rf "$WORK_DIR" 2>/dev/null; }
trap cleanup EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
fail() { log "FAIL: $*"; exit "${2:-1}"; }

# Slugify hostname (matches mempal_icloud_backup.sh).
HOST="$(hostname -s | tr -c '[:alnum:]_-' '-' | tr -s '-' | sed 's/^-//;s/-$//')"
[ -z "$HOST" ] && fail "could not determine hostname"

# Discover a Python with chromadb installed.
if [ -z "${MEMPAL_PYTHON:-}" ]; then
    for cand in \
        "$HOME/development/mempalace/.venv/bin/python" \
        "$HOME/.mempalace/.venv/bin/python" \
        "$(command -v python3)" \
        "$(command -v python)"; do
        if [ -n "$cand" ] && "$cand" -c "import chromadb" 2>/dev/null; then
            MEMPAL_PYTHON="$cand"; break
        fi
    done
fi
[ -z "${MEMPAL_PYTHON:-}" ] && fail "no python with chromadb found (set MEMPAL_PYTHON)"

command -v rclone >/dev/null 2>&1 || fail "rclone not installed"
[ -f "$MERGE_SCRIPT" ] || fail "merge script missing: $MERGE_SCRIPT"
[ -d "$SOURCE_DIR/palace" ] || fail "no local palace at $SOURCE_DIR/palace"

# 1. Tar local palace and push to R2 under our hostname slot.
SELF_TAR="$WORK_DIR/${HOST}.tar.gz"
log "tarring local palace -> $SELF_TAR"
if ! tar -czf "$SELF_TAR" -C "$HOME" .mempalace/ 2>/dev/null; then
    fail "tar failed"
fi
log "uploading $(du -h "$SELF_TAR" | cut -f1) to ${R2_REMOTE}:${R2_BUCKET}/${HOST}.tar.gz"
if ! rclone copyto "$SELF_TAR" "${R2_REMOTE}:${R2_BUCKET}/${HOST}.tar.gz" 2>>"$LOG_FILE"; then
    fail "rclone upload failed" 2
fi

# 2. List peers (every object in the bucket whose name isn't this host).
PEER_LIST="$(rclone lsf "${R2_REMOTE}:${R2_BUCKET}" 2>>"$LOG_FILE" | grep '\.tar\.gz$' | grep -v "^${HOST}\.tar\.gz$" || true)"
if [ -z "$PEER_LIST" ]; then
    log "no peer snapshots in bucket yet (self=${HOST}); upload-only run complete"
    exit 0
fi

# 3. Pull each peer, extract, merge.
TOTAL_NEW=0
while IFS= read -r peer_obj; do
    [ -z "$peer_obj" ] && continue
    peer_host="${peer_obj%.tar.gz}"
    peer_tar="$WORK_DIR/${peer_obj}"
    peer_extract="$WORK_DIR/peer_${peer_host}"
    log "pulling ${peer_obj}"
    if ! rclone copyto "${R2_REMOTE}:${R2_BUCKET}/${peer_obj}" "$peer_tar" 2>>"$LOG_FILE"; then
        log "WARN: rclone download failed for ${peer_obj}; skipping"
        continue
    fi
    mkdir -p "$peer_extract"
    if ! tar -xzf "$peer_tar" -C "$peer_extract" 2>/dev/null; then
        log "WARN: tar extract failed for ${peer_obj}; skipping"
        continue
    fi
    # Tarball top-level is .mempalace/, inside that is palace/
    peer_palace="$peer_extract/.mempalace/palace"
    if [ ! -d "$peer_palace" ]; then
        log "WARN: ${peer_obj} missing .mempalace/palace; skipping"
        continue
    fi
    log "merging from peer ${peer_host}"
    merge_out="$("$MEMPAL_PYTHON" "$MERGE_SCRIPT" "$peer_palace" 2>>"$LOG_FILE")" || {
        log "WARN: merge failed for ${peer_host}"; continue;
    }
    log "merge ${peer_host}: ${merge_out}"
    new_here="$(echo "$merge_out" | sed -n 's/.*"imported_to_local": *\([0-9]*\).*/\1/p')"
    [ -n "$new_here" ] && TOTAL_NEW=$((TOTAL_NEW + new_here))
done <<< "$PEER_LIST"

log "sync complete: imported ${TOTAL_NEW} new drawer(s) total"
