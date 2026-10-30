#!/bin/bash
# /usr/local/bin/pve-resource-monitor.sh
# Threshold Monitoring for RAM (>90%) and Storage (>85%)
set -eo pipefail

HOST=$(hostname)
NOW=$(date +%s)

# ---------------- RAM CHECK (> 90% for >= 10 mins) ----------------
RAM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
RAM_USED=$((RAM_TOTAL - RAM_AVAIL))
RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))
RAM_COUNT_FILE="/var/run/pve_ram_high_count"
RAM_ALERT_FILE="/var/run/pve_ram_alert_time"

if [ "$RAM_PCT" -ge 90 ]; then
    COUNT=0
    [ -f "$RAM_COUNT_FILE" ] && COUNT=$(cat "$RAM_COUNT_FILE")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$RAM_COUNT_FILE"

    if [ "$COUNT" -ge 2 ]; then
        # Check cooldown (2 hours = 7200 seconds)
        LAST_ALERT=0
        [ -f "$RAM_ALERT_FILE" ] && LAST_ALERT=$(cat "$RAM_ALERT_FILE")
        if [ $((NOW - LAST_ALERT)) -ge 7200 ]; then
            TOP_MEM=$(ps -eo pid,user,%mem,rss,comm --sort=-%mem | head -n 6)
            RAM_USED_GB=$(awk -v u="$RAM_USED" 'BEGIN {printf "%.1f", u/1024}')
            RAM_TOTAL_GB=$(awk -v t="$RAM_TOTAL" 'BEGIN {printf "%.1f", t/1024}')

            /usr/local/bin/discord-send.sh \
                --title "⚠️ Resource Alert: การใช้งาน RAM สูงเกินเกณฑ์ (${RAM_PCT}%)" \
                --desc "**แจ้งเตือน:** ระบบตรวจพบ RAM ใช้งานสูงเกิน 90% ต่อเนื่องเป็นเวลานาน (> 10 นาที)" \
                --color orange \
                --field "Host|${HOST}|true" \
                --field "Usage|${RAM_USED_GB}G / ${RAM_TOTAL_GB}G (${RAM_PCT}%)|true" \
                --field "Top Memory Consumers|\`\`\`text\n${TOP_MEM}\n\`\`\`|false"

            echo "$NOW" > "$RAM_ALERT_FILE"
        fi
    fi
else
    # Reset count if memory normalized below 85%
    if [ "$RAM_PCT" -lt 85 ]; then
        rm -f "$RAM_COUNT_FILE" "$RAM_ALERT_FILE"
    fi
fi

# ---------------- ROOT DISK CHECK (/) (> 85%) ----------------
ROOT_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
ROOT_ALERT_FILE="/var/run/pve_root_disk_alert_time"

if [ "$ROOT_PCT" -ge 85 ]; then
    LAST_ALERT=0
    [ -f "$ROOT_ALERT_FILE" ] && LAST_ALERT=$(cat "$ROOT_ALERT_FILE")
    if [ $((NOW - LAST_ALERT)) -ge 14400 ] || [ "$ROOT_PCT" -ge 95 ]; then
        COLOR="orange"
        [ "$ROOT_PCT" -ge 95 ] && COLOR="red"
        ROOT_USAGE=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')

        /usr/local/bin/discord-send.sh \
            --title "⚠️ Storage Alert: พื้นที่ Root Disk (/) ใกล้เต็ม (${ROOT_PCT}%)" \
            --desc "**คำเตือน:** พาร์ติชัน Root (/) เหลือพื้นที่เหลือน้อย กรุณาเคลียร์พื้นที่เพื่อป้องกันระบบหยุดชะงัก" \
            --color "$COLOR" \
            --field "Host|${HOST}|true" \
            --field "Mount Point|/ (Root)|true" \
            --field "Usage|${ROOT_USAGE}|true"

        echo "$NOW" > "$ROOT_ALERT_FILE"
    fi
else
    if [ "$ROOT_PCT" -lt 80 ]; then
        rm -f "$ROOT_ALERT_FILE"
    fi
fi

# ---------------- ZFS STORAGE POOLS CHECK (> 85%) ----------------
if command -v zpool >/dev/null 2>&1; then
    while read -r pool cap; do
        cap_val=$(echo "$cap" | tr -d '%')
        ZFS_ALERT_FILE="/var/run/pve_zfs_${pool}_alert_time"

        if [ "$cap_val" -ge 85 ]; then
            LAST_ALERT=0
            [ -f "$ZFS_ALERT_FILE" ] && LAST_ALERT=$(cat "$ZFS_ALERT_FILE")
            if [ $((NOW - LAST_ALERT)) -ge 14400 ] || [ "$cap_val" -ge 95 ]; then
                COLOR="orange"
                [ "$cap_val" -ge 95 ] && COLOR="red"
                POOL_STATUS=$(zpool list "$pool")

                /usr/local/bin/discord-send.sh \
                    --title "⚠️ Storage Alert: ZFS Pool '${pool}' ใกล้เต็ม (${cap_val}%)" \
                    --desc "**คำเตือน:** ZFS Pool มีการใช้งานพื้นที่เกิน 85% ประสิทธิภาพ Copy-on-Write อาจลดลง" \
                    --color "$COLOR" \
                    --field "Host|${HOST}|true" \
                    --field "Pool|${pool}|true" \
                    --field "Capacity|${cap_val}%|true" \
                    --field "Status|\`\`\`text\n${POOL_STATUS}\n\`\`\`|false"

                echo "$NOW" > "$ZFS_ALERT_FILE"
            fi
        else
            if [ "$cap_val" -lt 80 ]; then
                rm -f "$ZFS_ALERT_FILE"
            fi
        fi
    done < <(zpool list -H -o name,cap 2>/dev/null || true)
fi

exit 0