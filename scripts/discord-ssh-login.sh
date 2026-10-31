#!/bin/bash
# /usr/local/bin/discord-ssh-login.sh
# SSH Root Login Alert for Discord (triggered by PAM)

[ "$PAM_TYPE" = "open_session" ] || exit 0
[ "$PAM_USER" = "root" ] || exit 0

RHOST="${PAM_RHOST:-Unknown}"
if [ "$RHOST" = "127.0.0.1" ] || [ "$RHOST" = "::1" ] || [ "$RHOST" = "localhost" ]; then
    exit 0
fi

LOCK_FILE="/dev/shm/ssh_alert_${RHOST//[^a-zA-Z0-9_.-]/_}.lock"
NOW=$(date +%s)
if [ -f "$LOCK_FILE" ]; then
    LAST=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
    if [ $((NOW - LAST)) -lt 60 ]; then
        exit 0
    fi
fi
echo "$NOW" > "$LOCK_FILE"

CONF_FILE="/etc/pve-discord.conf"
SSH_WEBHOOK=""
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
    SSH_WEBHOOK="${DISCORD_SSH_WEBHOOK_URL:-}"
fi

(
    HOST=$(hostname)
    DATE_STR=$(date '+%Y-%m-%d %H:%M:%S')
    TTY_INFO="${PAM_TTY:-non-interactive}"
    ROOT_SESSIONS=$(who 2>/dev/null | grep -c '^root' || echo "1")

    CMD_ARGS=(
        "/usr/local/bin/discord-send.sh"
        "--tag"
        "--title" "🛡️ Security Alert: ตรวจพบการเข้าสู่ระบบ SSH Root"
        "--desc" "**แจ้งเตือนความปลอดภัย:** มีการล็อกอินเข้าใช้งานเซิร์ฟเวอร์ด้วยสิทธิ์ \`root\`"
        "--color" "orange"
        "--field" "User" "root" "true"
        "--field" "Remote IP" "${RHOST}" "true"
        "--field" "Host" "${HOST}" "true"
        "--field" "Time" "${DATE_STR}" "true"
        "--field" "Session TTY" "${TTY_INFO}" "true"
        "--field" "Active Sessions" "${ROOT_SESSIONS}" "true"
    )

    if [ -n "$SSH_WEBHOOK" ]; then
        CMD_ARGS+=("--webhook" "$SSH_WEBHOOK")
    fi

    "${CMD_ARGS[@]}"
) >/dev/null 2>&1 &

exit 0
