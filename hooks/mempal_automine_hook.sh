#!/bin/bash
# MEMPALACE AUTO-MINE HOOK — Index conversations after sessions
#
# Claude Code "Stop" hook. Runs mempalace mine on conversation
# transcripts in the background, throttled to at most once per hour.
# Non-blocking — never interferes with the conversation.
#
# How it works:
# 1. Checks when mining last ran (timestamp file)
# 2. If >60 minutes ago, kicks off mining in the background
# 3. mempalace's built-in mtime tracking skips unchanged files
# 4. Returns empty JSON — never blocks the AI

MINE_INTERVAL=300  # seconds between mines (5 min cooldown to avoid rapid re-mining)
STATE_DIR="$HOME/.mempalace/hook_state"
LAST_MINE_FILE="$STATE_DIR/last_automine"
MINE_LOG="$STATE_DIR/automine.log"
VENV_PYTHON="/Users/adaymesa/development/mempalace/.venv/bin/python3"
CONVOS_DIR="$HOME/.claude/projects"

mkdir -p "$STATE_DIR"

# Read stdin (required by hook protocol) but we don't need the data
cat > /dev/null

# Check throttle
LAST_MINE=0
if [ -f "$LAST_MINE_FILE" ]; then
    LAST_MINE=$(cat "$LAST_MINE_FILE")
fi

NOW=$(date +%s)
ELAPSED=$((NOW - LAST_MINE))

if [ "$ELAPSED" -ge "$MINE_INTERVAL" ]; then
    echo "$NOW" > "$LAST_MINE_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Auto-mining conversations from $CONVOS_DIR" >> "$MINE_LOG"

    # Run in background: mine then notify
    (
        "$VENV_PYTHON" -m mempalace mine "$CONVOS_DIR" --mode convos >> "$MINE_LOG" 2>&1
        osascript -e 'display notification "Session indexed" with title "MemPalace" sound name "Purr"' 2>/dev/null
    ) &

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Mining started (PID: $!)" >> "$MINE_LOG"
fi

# Never block — always let the AI proceed
echo "{}"
