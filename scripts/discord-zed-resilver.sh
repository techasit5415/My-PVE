#!/bin/bash
# /usr/local/bin/discord-zed-resilver.sh
# ZED Event Handler for ZFS Resilver & Scrub Notifications (3-Tier Critical / Warning / Info)
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

POOL_STATUS=$(zpool status "$POOL" 2>/dev/null | grep -E "scan:|state:|status:|errors:" | sed 's/^[ \t]*//' || echo "N/A")

# Check ZFS READ/WRITE/CKSUM counters on pool
ZFS_ERR_LINES=$(zpool status -P "$POOL" 2>/dev/null | awk '
    /^[[:space:]]+\/dev\// || /^[[:space:]]+(mirror|raidz|spare|logs|cache)/ {
        r=$(NF-2); w=$(NF-1); c=$NF;
        if ((r+0 > 0) || (w+0 > 0) || (c+0 > 0)) print $0
    }' || true)
KNOWN_DATA_ERRS=$(zpool status -x "$POOL" 2>/dev/null | grep -ic "Known data errors" || true)

# Check SMART ID 5, 197, 198 on all /dev/sd* disks in this pool
CRIT_DISKS=""
if command -v smartctl >/dev/null 2>&1; then
    for devpath in /dev/sd[a-z] /dev/sd[a-z][a-z]; do
        [ -b "$devpath" ] || continue
        h_out=$(smartctl -H "$devpath" 2>/dev/null || true)
        a_out=$(smartctl -A "$devpath" 2>/dev/null || true)
        realloc=$(echo "$a_out" | awk '/Reallocated_Sector_Ct/{print $10+0}' | head -n 1); realloc=${realloc:-0}
        pending=$(echo "$a_out" | awk '/Current_Pending_Sector/{print $10+0}' | head -n 1); pending=${pending:-0}
        uncorr=$(echo "$a_out" | awk '/Offline_Uncorrectable/{print $10+0}' | head -n 1); uncorr=${uncorr:-0}
        h_fail=0
        echo "$h_out" | grep -Eqi 'PASSED|OK' || h_fail=1
        if [ "$h_fail" -eq 1 ] || [ "$realloc" -gt 0 ] || [ "$pending" -gt 0 ] || [ "$uncorr" -gt 0 ]; then
            sn=$(lsblk -d -no SERIAL "$devpath" 2>/dev/null | xargs || echo "Unknown")
            CRIT_DISKS="${CRIT_DISKS}${devpath} (S/N: ${sn} | Pending: ${pending} / Realloc: ${realloc} / Uncorr: ${uncorr})\n"
        fi
    done
fi

USE_TAG=1
if [ "$SUBCLASS" = "resilver_start" ]; then
    TITLE="🔄 ZFS Resilver Started: พูล $POOL"
    DESC="**แจ้งเตือน ZFS:** ระบบเริ่มทำการ Resilver / Rebuild ข้อมูลในพูล \`$POOL\`"
    COLOR="blue"
elif [ "$SUBCLASS" = "resilver_finish" ] || [ "$SUBCLASS" = "scrub_finish" ]; then
    if [ -n "$CRIT_DISKS" ]; then
        TITLE="🔴 Disk Critical (ใกล้เสีย/พบ Bad Sector): พูล $POOL"
        DESC="**แจ้งเตือนด่วน:** การ \`${SUBCLASS}\` บนพูล \`$POOL\` พบดิสก์มี Bad Sector เสี่ยงข้อมูลสูญหายหากลูกคู่แฝดพังตาม กรุณาเตรียมดิสก์สำรองเพื่อทำ \`zpool replace\` ทันที\n\`\`\`text\n${CRIT_DISKS}\`\`\`"
        COLOR="red"
    elif [ -n "$ZFS_ERR_LINES" ] || [ "$KNOWN_DATA_ERRS" -gt 0 ]; then
        TITLE="🟡 Disk/Pool Warning (อ่าน-เขียนสะดุด / ตรวจสอบการเชื่อมต่อ): พูล $POOL"
        DESC="พูล \`$POOL\` พบข้อผิดพลาดในการส่งข้อมูล (CRC Error / ZFS Checksum / READ-WRITE-CKSUM > 0) แต่ **ยังไม่พบ Bad Sector ถาวร (SMART ID 5/197/198 = 0)** แนะนำให้ตรวจสอบสาย SATA/Power และรัน \`zpool status -v\` เพื่อดูว่าต้อง \`zpool clear\` หรือไม่"
        COLOR="yellow"
    else
        TITLE="🟢 ZFS Healthy (ซ่อมแซมข้อมูลเสร็จสมบูรณ์): พูล $POOL"
        DESC="การ Resilver/Scrub บนพูล \`$POOL\` เสร็จสิ้นโดยไม่พบข้อผิดพลาดใหม่ (READ/WRITE/CKSUM = 0, Bad Sector = 0) สถานะพูลปกติ"
        COLOR="green"
        USE_TAG=0
    fi
else
    TITLE="ℹ️ ZFS Event: $SUBCLASS (พูล $POOL)"
    DESC="เหตุการณ์ ZFS สำหรับพูล \`$POOL\`"
    COLOR="blue"
    USE_TAG=0
fi

CMD=(
    "/usr/local/bin/discord-send.sh"
    "--webhook" "$RESILVER_WEBHOOK"
    "--title" "$TITLE"
    "--desc" "$DESC"
    "--color" "$COLOR"
    "--field" "Host|${HOST}|true"
    "--field" "Pool|${POOL}|true"
    "--field" "Event|${SUBCLASS}|true"
    "--field" "Time|${TIME_STR}|false"
    "--field" "Pool Summary|\`\`\`text\n${POOL_STATUS}\n\`\`\`|false"
)

if [ "$USE_TAG" -eq 1 ]; then
    CMD+=("--tag")
fi

"${CMD[@]}"
