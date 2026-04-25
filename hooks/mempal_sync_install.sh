#!/bin/bash
# mempal_sync_install.sh — one-shot installer for cross-machine MemPalace sync.
# Sets up rclone for Cloudflare R2, writes ~/.mempalace.sync.env, schedules
# the daily sync via launchd (macOS) or cron (Linux/WSL).
#
# Run on each machine ONCE. Re-running is safe (config + schedule overwritten).
#
# Configuration: prefers env vars, falls back to interactive prompts.
#   MEMPAL_R2_ACCESS_KEY_ID
#   MEMPAL_R2_SECRET_ACCESS_KEY
#   MEMPAL_R2_ACCOUNT_ID
#   MEMPAL_R2_BUCKET           (default: mempalace-sync)
#   MEMPAL_R2_REMOTE           (default: mempal_r2)
#   MEMPAL_SYNC_HOUR           (default: 3)
#   MEMPAL_SYNC_MINUTE         (default: 30)

set -euo pipefail

prompt_if_unset() {
    local var="$1" message="$2" silent="${3:-no}"
    if [ -z "${!var:-}" ]; then
        if [ "$silent" = "yes" ]; then
            read -rsp "$message: " val; echo
        else
            read -rp "$message: " val
        fi
        printf -v "$var" '%s' "$val"
    fi
}

install_rclone() {
    if command -v rclone >/dev/null 2>&1; then
        echo "rclone present: $(rclone version | head -1)"
        return
    fi
    echo "installing rclone..."
    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                brew install rclone
            else
                curl -fsSL https://rclone.org/install.sh | sudo bash
            fi
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update && sudo apt-get install -y rclone
            else
                curl -fsSL https://rclone.org/install.sh | sudo bash
            fi
            ;;
        *)
            echo "unsupported OS: $(uname -s)" >&2; exit 1;;
    esac
}

write_rclone_config() {
    local cfg="$HOME/.config/rclone/rclone.conf"
    mkdir -p "$(dirname "$cfg")"
    # Strip any prior section with the same name, then append the fresh one.
    if [ -f "$cfg" ]; then
        awk -v sec="[$MEMPAL_R2_REMOTE]" '
            $0 == sec { skip=1; next }
            /^\[.*\]$/ { skip=0 }
            !skip { print }
        ' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    fi
    cat >> "$cfg" <<EOF

[$MEMPAL_R2_REMOTE]
type = s3
provider = Cloudflare
access_key_id = $MEMPAL_R2_ACCESS_KEY_ID
secret_access_key = $MEMPAL_R2_SECRET_ACCESS_KEY
endpoint = https://${MEMPAL_R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
EOF
    chmod 600 "$cfg"
}

write_env_file() {
    local env_file="$HOME/.mempalace.sync.env"
    cat > "$env_file" <<EOF
MEMPAL_R2_REMOTE=$MEMPAL_R2_REMOTE
MEMPAL_R2_BUCKET=$MEMPAL_R2_BUCKET
EOF
    chmod 600 "$env_file"
}

ensure_bucket_exists() {
    if rclone lsf "${MEMPAL_R2_REMOTE}:${MEMPAL_R2_BUCKET}" >/dev/null 2>&1; then
        echo "bucket ${MEMPAL_R2_BUCKET} reachable"
        return
    fi
    echo "creating bucket ${MEMPAL_R2_BUCKET}..."
    rclone mkdir "${MEMPAL_R2_REMOTE}:${MEMPAL_R2_BUCKET}"
}

schedule_macos() {
    local sync_script="$1"
    local plist="$HOME/Library/LaunchAgents/com.mempalace.sync.plist"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.mempalace.sync</string>
    <key>ProgramArguments</key>
    <array><string>$sync_script</string></array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>$MEMPAL_SYNC_HOUR</integer>
        <key>Minute</key><integer>$MEMPAL_SYNC_MINUTE</integer>
    </dict>
    <key>StandardOutPath</key><string>/tmp/com.mempalace.sync.out</string>
    <key>StandardErrorPath</key><string>/tmp/com.mempalace.sync.err</string>
</dict>
</plist>
EOF
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist"
    echo "scheduled via launchd at ${MEMPAL_SYNC_HOUR}:${MEMPAL_SYNC_MINUTE} daily"
}

schedule_cron() {
    local sync_script="$1"
    local cron_line="$MEMPAL_SYNC_MINUTE $MEMPAL_SYNC_HOUR * * * $sync_script >/dev/null 2>&1"
    # Replace any existing mempal_sync line, append fresh one.
    (crontab -l 2>/dev/null | grep -v 'mempal_sync\.sh' || true; echo "$cron_line") | crontab -
    echo "scheduled via cron at ${MEMPAL_SYNC_HOUR}:${MEMPAL_SYNC_MINUTE} daily"
}

main() {
    install_rclone

    : "${MEMPAL_R2_REMOTE:=mempal_r2}"
    : "${MEMPAL_R2_BUCKET:=mempalace-sync}"
    : "${MEMPAL_SYNC_HOUR:=3}"
    : "${MEMPAL_SYNC_MINUTE:=30}"
    prompt_if_unset MEMPAL_R2_ACCESS_KEY_ID "R2 Access Key ID"
    prompt_if_unset MEMPAL_R2_SECRET_ACCESS_KEY "R2 Secret Access Key" yes
    prompt_if_unset MEMPAL_R2_ACCOUNT_ID "R2 Account ID (the part before .r2.cloudflarestorage.com)"

    write_rclone_config
    write_env_file
    ensure_bucket_exists

    local sync_script
    sync_script="$(cd "$(dirname "$0")" && pwd)/mempal_sync.sh"
    [ -x "$sync_script" ] || { echo "sync script not executable: $sync_script" >&2; exit 1; }

    case "$(uname -s)" in
        Darwin) schedule_macos "$sync_script" ;;
        Linux)  schedule_cron  "$sync_script" ;;
        *)      echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
    esac

    echo
    echo "install complete."
    echo "  test now:  $sync_script && tail -20 ~/.mempalace.sync.log"
    echo "  daily run: ${MEMPAL_SYNC_HOUR}:${MEMPAL_SYNC_MINUTE} local time"
}

main "$@"
