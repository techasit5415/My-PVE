#!/bin/bash
# /usr/local/bin/pve-resource-monitor.sh
# Resource & Disk Health Monitoring for Proxmox VE
set -eo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

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

# ---------------- ZFS RESILVER PROGRESS MONITOR ----------------
if command -v zpool >/dev/null 2>&1; then
    CONF_FILE="/etc/pve-discord.conf"
    RES_WH=""
    [ -f "$CONF_FILE" ] && . "$CONF_FILE" && RES_WH="${DISCORD_RESILVER_WEBHOOK_URL:-}"

    for p_name in $(zpool list -H -o name 2>/dev/null); do
        SCAN_LINE=$(zpool status "$p_name" 2>/dev/null | grep -E "scan:" || true)
        PROGRESS_LOCK="/var/run/pve_resilver_${p_name}_progress"

        if echo "$SCAN_LINE" | grep -qi "resilver in progress"; then
            PROG_DETAIL=$(echo "$SCAN_LINE" | sed "s/^[ \t]*scan:[ \t]*//")
            CUR_TIME=$(date +%s)
            LAST_REPORT=0
            [ -f "$PROGRESS_LOCK" ] && LAST_REPORT=$(cat "$PROGRESS_LOCK" 2>/dev/null || echo 0)

            # Send progress every 15 minutes (900 seconds) while resilvering
            if [ $((CUR_TIME - LAST_REPORT)) -ge 900 ]; then
                echo "$CUR_TIME" > "$PROGRESS_LOCK"
                /usr/local/bin/discord-send.sh \
                    ${RES_WH:+--webhook "$RES_WH"} \
                    --title "⏳ ZFS Resilver in Progress: พูล $p_name" \
                    --desc "**อัปเดตสถานะ Resilver:** กำลังซิงก์ข้อมูลเข้าสู่ดิสก์ลูกใหม่" \
                    --color "yellow" \
                    --field "Host" "$(hostname)" "true" \
                    --field "Pool" "$p_name" "true" \
                    --field "Status" "Resilvering" "true" \
                    --field "Progress" "```text\n$PROG_DETAIL\n```" "false"
            fi
        else
            rm -f "$PROGRESS_LOCK"
        fi
    done
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

# ---------------- DISK S.M.A.R.T. & LED LOCATE CHECK ----------------
if command -v smartctl >/dev/null 2>&1; then
    for devpath in /dev/sd[a-z] /dev/sd[a-z][a-z]; do
        [ -b "$devpath" ] || continue
        d=$(basename "$devpath")

        # 1. SMART Health Status
        h_out=$(smartctl -H "$devpath" 2>/dev/null || true)
        is_bad=0
        if ! echo "$h_out" | grep -Eqi 'PASSED|OK'; then
            is_bad=1
        fi

        # 2. Reallocated / Grown defect sectors
        a_out=$(smartctl -A "$devpath" 2>/dev/null || true)
        bad_cnt=0

        # SATA: Reallocated_Sector_Ct
        realloc=$(echo "$a_out" | awk '/Reallocated_Sector_Ct/{print $10}')
        [ -n "$realloc" ] && [ "$realloc" -gt 0 ] 2>/dev/null && bad_cnt=$realloc

        # SAS: Elements in grown defect list
        grown=$(echo "$a_out" | awk -F: '/Elements in grown defect list/{gsub(/ /, "", $2); print $2}')
        [ -n "$grown" ] && [ "$grown" -gt 0 ] 2>/dev/null && bad_cnt=$grown

        # Current pending sectors
        pending=$(echo "$a_out" | awk '/Current_Pending_Sector/{print $10}')
        [ -n "$pending" ] && [ "$pending" -gt 0 ] 2>/dev/null && bad_cnt=$((bad_cnt + pending))

        if [ "$is_bad" -eq 1 ] || [ "$bad_cnt" -gt 0 ]; then
            # Turn ON Locate LED (Blinking indicator if supported)
            command -v ledctl >/dev/null 2>&1 && ledctl locate="$devpath" >/dev/null 2>&1 || true

            # Extract Model, Serial Number, Size
            model=$(lsblk -d -no MODEL "$devpath" 2>/dev/null | xargs || true)
            serial=$(lsblk -d -no SERIAL "$devpath" 2>/dev/null | xargs || true)
            size=$(lsblk -d -no SIZE "$devpath" 2>/dev/null | xargs || true)
            if [ -z "$model" ] || [ -z "$serial" ]; then
                i_out=$(smartctl -i "$devpath" 2>/dev/null || true)
                [ -z "$model" ] && model=$(echo "$i_out" | awk -F: '/Device Model|Model Number|Product/{print $2}' | head -n 1 | xargs || true)
                [ -z "$serial" ] && serial=$(echo "$i_out" | awk -F: '/Serial Number/{print $2}' | head -n 1 | xargs || true)
            fi

            led_state="No LED backplane"
            command -v ledctl >/dev/null 2>&1 && led_state="Blinking (locate=on)"

            DISK_ALERT_FILE="/var/run/pve_disk_${d}_alert_time"
            LAST_ALERT=0
            [ -f "$DISK_ALERT_FILE" ] && LAST_ALERT=$(cat "$DISK_ALERT_FILE")
            if [ $((NOW - LAST_ALERT)) -ge 43200 ]; then
                /usr/local/bin/discord-send.sh \
                    --tag \
                    --title "🚨 Disk Failure/Warning: ตรวจพบความผิดปกติของดิสก์ ${d}" \
                    --desc "**เซิร์ฟเวอร์:** \`${HOST}\` ตรวจพบ Bad Sector หรือความผิดปกติของดิสก์ กรุณาเตรียมเปลี่ยนดิสก์ลูกนี้" \
                    --color red \
                    --field "Host|${HOST}|true" \
                    --field "Device|${devpath}|true" \
                    --field "Model|${model:-Unknown}|true" \
                    --field "Serial Number (S/N)|\`${serial:-Unknown}\`|true" \
                    --field "Capacity|${size:-Unknown}|true" \
                    --field "Bad/Pending Sectors|${bad_cnt}|true" \
                    --field "Tray LED|${led_state}|true"
                echo "$NOW" > "$DISK_ALERT_FILE"
            fi
        else
            # Healthy: Turn OFF Locate LED
            command -v ledctl >/dev/null 2>&1 && ledctl locate_off="$devpath" >/dev/null 2>&1 || true
            rm -f "/var/run/pve_disk_${d}_alert_time"
        fi
    done
fi

exit 0