#!/bin/bash
# /usr/local/bin/discord-ssh-login.sh
# SSH Root Login Alert for Discord (triggered by PAM)

# Only trigger on session open for root user
[ "$PAM_TYPE" = "open_session" ] || exit 0
[ "$PAM_USER" = "root" ] || exit 0

RHOST="${PAM_RHOST:-Unknown}"
# Skip if connection is local loopback
if [ "$RHOST" = "127.0.0.1" ] || [ "$RHOST" = "::1" ] || [ "$RHOST" = "localhost" ]; then
    exit 0
fi

# Rate-limit cooldown: at most 1 alert per remote IP every 60 seconds
LOCK_FILE="/dev/shm/ssh_alert_${RHOST//[^a-zA-Z0-9_.-]/_}.lock"
NOW=$(date +%s)
if [ -f "$LOCK_FILE" ]; then
    LAST=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
    if [ $((NOW - LAST)) -lt 60 ]; then
        exit 0
    fi
fi
echo "$NOW" > "$LOCK_FILE"

# Send notification asynchronously in background so SSH is never delayed
(
    HOST=$(hostname)
    DATE_STR=$(date '+%Y-%m-%d %H:%M:%S')
    TTY_INFO="${PAM_TTY:-non-interactive}"
    ROOT_SESSIONS=$(who 2>/dev/null | grep -c '^root' || echo "1")

    /usr/local/bin/discord-send.sh \
        --title "🛡️ Security Alert: ตรวจพบการเข้าสู่ระบบ SSH Root" \
        --desc "**แจ้งเตือนความปลอดภัย:** มีการล็อกอินเข้าใช้งานเซิร์ฟเวอร์ด้วยสิทธิ์ \`root\`" \
        --color orange \
        --field "User|root|true" \
        --field "Remote IP|${RHOST}|true" \
        --field "Host|${HOST}|true" \
        --field "Time|${DATE_STR}|true" \
        --field "Session TTY|${TTY_INFO}|true" \
        --field "Active Sessions|${ROOT_SESSIONS}|true"
) >/dev/null 2>&1 &

exit 0