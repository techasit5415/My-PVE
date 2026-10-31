#!/bin/bash
# /usr/local/bin/discord-zed-resilver.sh
# ZED Event Handler for ZFS Resilver Notifications to Discord
set -uo pipefail

CONF_FILE="/etc/pve-discord.conf"
RESILVER_WEBHOOK=""
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
    RESILVER_WEBHOOK="${DISCORD_RESILVER_WEBHOOK_URL:-$DISCORD_WEBHOOK_URL}"
fi

[ -z "$RESILVER_WEBHOOK" ] && exit 0

POOL="${ZEVENT_POOL:-Unknown}"
SUBCLASS="${ZEVENT_SUBCLASS:-resilver_event}"
HOST="$(hostname)"
TIME_STR="${ZEVENT_TIME_STRING:-$(date '+%Y-%m-%d %H:%M:%S')}"

POOL_STATUS=$(zpool status "$POOL" 2>/dev/null | grep -E "scan:|state:|status:" | sed 's/^[ \t]*//' || echo "N/A")

if [ "$SUBCLASS" = "resilver_start" ]; then
    TITLE="🔄 ZFS Resilver Started: พูล $POOL"
    DESC="**แจ้งเตือน ZFS:** ระบบเริ่มทำการ Resilver / Rebuild ข้อมูลในพูล \`$POOL\`"
    COLOR="yellow"
elif [ "$SUBCLASS" = "resilver_finish" ]; then
    ERR_CNT=$(zpool status -x "$POOL" 2>/dev/null | grep -ic "errors:" || true)
    if [ "$ERR_CNT" -gt 0 ]; then
        TITLE="⚠️ ZFS Resilver Finished with Errors: พูล $POOL"
        DESC="**แจ้งเตือน ZFS:** การ Resilver ในพูล \`$POOL\` เสร็จสิ้นแต่พบข้อผิดพลาด กรุณาตรวจสอบสถานะพูลทันที"
        COLOR="red"
    else
        TITLE="✅ ZFS Resilver Completed: พูล $POOL"
        DESC="**แจ้งเตือน ZFS:** การ Resilver / Rebuild ข้อมูลในพูล \`$POOL\` เสร็จสมบูรณ์แล้ว พูลกลับสู่สถานะปกติ"
        COLOR="green"
    fi
else
    TITLE="ℹ️ ZFS Resilver Event: $SUBCLASS"
    DESC="เหตุการณ์ ZFS สำหรับพูล \`$POOL\`"
    COLOR="blue"
fi

/usr/local/bin/discord-send.sh \
    --webhook "$RESILVER_WEBHOOK" \
    --tag \
    --title "$TITLE" \
    --desc "$DESC" \
    --color "$COLOR" \
    --field "Host|${HOST}|true" \
    --field "Pool|${POOL}|true" \
    --field "Event|${SUBCLASS}|true" \
    --field "Time|${TIME_STR}|false" \
    --field "Pool Summary|\`\`\`text\n${POOL_STATUS}\n\`\`\`|false"
