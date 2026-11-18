#!/bin/bash
# /usr/local/bin/pve-resource-monitor.sh
# Resource, ZFS & 3-Tier Disk Health Monitoring for Proxmox VE
set -eo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

HOST=$(hostname)
NOW=$(date +%s)

# ---------------- RAM CHECK (> 90% for >= 10 mins, excluding reclaimable ZFS ARC) ----------------
RAM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
ARC_RECLAIM_MB=0
if [ -r /proc/spl/kstat/zfs/arcstats ]; then
    ARC_RECLAIM_MB=$(awk '
        $1 == "size" { s = $3 }
        $1 == "c_min" { m = $3 }
        END {
            r = int((s - m) / 1048576)
            print (r > 0 ? r : 0)
        }
    ' /proc/spl/kstat/zfs/arcstats)
fi
RAM_USED=$((RAM_TOTAL - RAM_AVAIL - ARC_RECLAIM_MB))
[ "$RAM_USED" -lt 0 ] && RAM_USED=0
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
    echo "0" > "$RAM_COUNT_FILE"
    rm -f "$RAM_ALERT_FILE"
fi

# ---------------- ROOT DISK CHECK (> 85%) ----------------
ROOT_PCT=$(df / | awk 'NR==2 {gsub("%",""); print $5}')
ROOT_ALERT_FILE="/var/run/pve_root_alert_time"

if [ "$ROOT_PCT" -ge 85 ]; then
    LAST_ALERT=0
    [ -f "$ROOT_ALERT_FILE" ] && LAST_ALERT=$(cat "$ROOT_ALERT_FILE")
    if [ $((NOW - LAST_ALERT)) -ge 43200 ]; then
        COLOR="orange"
        [ "$ROOT_PCT" -ge 95 ] && COLOR="red"
        ROOT_USAGE=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')

        /usr/local/bin/discord-send.sh \
            --title "⚠️ Storage Alert: พื้นที่ Root Disk (/) ใกล้เต็ม (${ROOT_PCT}%)" \
            --desc "**คำเตือน:** พาร์ติชัน Root (/) เหลือพื้นที่เหลือน้อย กรุณาเคลียร์พื้นที่เพื่อป้องกันระบบหยุดชะงัก" \
            --color "$COLOR" \
            --field "Host|${HOST}|true" \
            --field "Mountpoint|/|true" \
            --field "Usage|${ROOT_USAGE}|true"

        echo "$NOW" > "$ROOT_ALERT_FILE"
    fi
else
    if [ "$ROOT_PCT" -lt 80 ]; then
        rm -f "$ROOT_ALERT_FILE"
    fi
fi

# ---------------- ZFS POOL RESILVER PROGRESS & HEALTH CHECK ----------------
ANY_DISK_CRITICAL=0

if command -v zpool >/dev/null 2>&1; then
    # Resilver progress report every 15 mins
    RESILVER_POOLS=$(zpool status 2>/dev/null | awk '/pool:/{p=$2} /resilver in progress/{print p}')
    if [ -n "$RESILVER_POOLS" ]; then
        CONF_FILE="/etc/pve-discord.conf"
        RES_WH=""
        if [ -f "$CONF_FILE" ]; then
            . "$CONF_FILE"
            RES_WH="${DISCORD_RESILVER_WEBHOOK_URL:-}"
        fi
        for p_name in $RESILVER_POOLS; do
            PROGRESS_LOCK="/var/run/zfs_resilver_prog_${p_name}.lock"
            LAST_REPORT=0
            [ -f "$PROGRESS_LOCK" ] && LAST_REPORT=$(cat "$PROGRESS_LOCK" 2>/dev/null || echo 0)
            CUR_TIME=$(date +%s)
            if [ $((CUR_TIME - LAST_REPORT)) -ge 900 ]; then
                echo "$CUR_TIME" > "$PROGRESS_LOCK"
                /usr/local/bin/discord-send.sh \
                    ${RES_WH:+--webhook "$RES_WH"} \
                    --title "⏳ ZFS Resilver in Progress: พูล $p_name" \
                    --desc "**อัปเดตสถานะ Resilver:** กำลังซิงก์ข้อมูลเข้าสู่ดิสก์ลูกใหม่" \
                    --color blue \
                    --field "Host|${HOST}|true" \
                    --field "Pool|${p_name}|true" \
                    --field "Progress Details|\`\`\`text\n$(zpool status "$p_name" 2>/dev/null | grep -E "scan:|resilvered|to go|issued|state:" | sed 's/^[ \t]*//')\n\`\`\`|false"
            fi
        done
    else
        rm -f /var/run/zfs_resilver_prog_*.lock 2>/dev/null || true
    fi

    # ZFS Pool capacity > 85%
    while IFS=$'\t' read -r pool cap; do
        [ -z "$pool" ] && continue
        cap_val=${cap%\%}
        [ -z "$cap_val" ] && continue
        ZFS_ALERT_FILE="/var/run/pve_zfs_${pool}_alert_time"

        if [ "$cap_val" -ge 85 ] 2>/dev/null; then
            LAST_ALERT=0
            [ -f "$ZFS_ALERT_FILE" ] && LAST_ALERT=$(cat "$ZFS_ALERT_FILE")
            if [ $((NOW - LAST_ALERT)) -ge 43200 ]; then
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
            if [ "$cap_val" -lt 80 ] 2>/dev/null; then
                rm -f "$ZFS_ALERT_FILE"
            fi
        fi
    done < <(zpool list -H -o name,cap 2>/dev/null || true)
fi

# ---------------- 3-TIER DISK S.M.A.R.T. & LED LOCATE CHECK ----------------
SMART_STATE_DIR="/var/lib/pve-smart-state"
mkdir -p "$SMART_STATE_DIR"

if command -v smartctl >/dev/null 2>&1; then
    for devpath in /dev/sd[a-z] /dev/sd[a-z][a-z]; do
        [ -b "$devpath" ] || continue
        d=$(basename "$devpath")

        # 1. SMART Health & Self-Test Status
        h_out=$(smartctl -H "$devpath" 2>/dev/null || true)
        health_failed=0
        if ! echo "$h_out" | grep -Eqi 'PASSED|OK'; then
            health_failed=1
        fi

        l_out=$(smartctl -l selftest "$devpath" 2>/dev/null || true)
        selftest_failed=0
        if echo "$l_out" | grep -E '^\s*#\s*1\s+' | grep -Eqi 'read failure|FAILED|Completed:.*failure'; then
            selftest_failed=1
        fi

        # 2. SMART Attributes: Critical (ID 5, 197, 198, SAS Grown) & Warning (ID 199 CRC, ID 188 Timeout)
        a_out=$(smartctl -A "$devpath" 2>/dev/null || true)

        realloc=$(echo "$a_out" | awk '/Reallocated_Sector_Ct/{print $10+0}' | head -n 1)
        realloc=${realloc:-0}

        grown=$(echo "$a_out" | awk -F: '/Elements in grown defect list/{gsub(/ /, "", $2); print $2+0}' | head -n 1)
        grown=${grown:-0}
        [ "$grown" -gt "$realloc" ] 2>/dev/null && realloc=$grown

        pending=$(echo "$a_out" | awk '/Current_Pending_Sector/{print $10+0}' | head -n 1)
        pending=${pending:-0}

        uncorr=$(echo "$a_out" | awk '/Offline_Uncorrectable/{print $10+0}' | head -n 1)
        uncorr=${uncorr:-0}

        crc_err=$(echo "$a_out" | awk '/UDMA_CRC_Error_Count/{print $10+0}' | head -n 1)
        crc_err=${crc_err:-0}

        cmd_timeout=$(echo "$a_out" | awk '/Command_Timeout/{print $10+0}' | head -n 1)
        cmd_timeout=${cmd_timeout:-0}

        # Extract Model, Serial Number, Size
        model=$(lsblk -d -no MODEL "$devpath" 2>/dev/null | xargs || true)
        serial=$(lsblk -d -no SERIAL "$devpath" 2>/dev/null | xargs || true)
        size=$(lsblk -d -no SIZE "$devpath" 2>/dev/null | xargs || true)
        if [ -z "$model" ] || [ -z "$serial" ]; then
            i_out=$(smartctl -i "$devpath" 2>/dev/null || true)
            [ -z "$model" ] && model=$(echo "$i_out" | awk -F: '/Device Model|Model Number|Product/{print $2}' | head -n 1 | xargs || true)
            [ -z "$serial" ] && serial=$(echo "$i_out" | awk -F: '/Serial Number/{print $2}' | head -n 1 | xargs || true)
        fi

        # TIER 1: CRITICAL (Physical Media / Head Failure)
        if [ "$health_failed" -eq 1 ] || [ "$selftest_failed" -eq 1 ] || [ "$realloc" -gt 0 ] || [ "$pending" -gt 0 ] || [ "$uncorr" -gt 0 ]; then
            ANY_DISK_CRITICAL=1
            command -v ledctl >/dev/null 2>&1 && ledctl locate="$devpath" >/dev/null 2>&1 || true

            led_state="No LED backplane"
            command -v ledctl >/dev/null 2>&1 && led_state="Blinking (locate=on)"

            health_reason="SMART Health: PASSED"
            [ "$health_failed" -eq 1 ] && health_reason="SMART Health: FAILED"
            [ "$selftest_failed" -eq 1 ] && health_reason="${health_reason} / Self-test: read failure"

            DISK_CRIT_FILE="/var/run/pve_disk_${d}_crit_time"
            LAST_ALERT=0
            [ -f "$DISK_CRIT_FILE" ] && LAST_ALERT=$(cat "$DISK_CRIT_FILE" 2>/dev/null || echo 0)
            if [ $((NOW - LAST_ALERT)) -ge 43200 ]; then
                /usr/local/bin/discord-send.sh \
                    --tag \
                    --title "🔴 Disk Critical (ใกล้เสีย/พบ Bad Sector): ${devpath}" \
                    --desc "**เซิร์ฟเวอร์:** \`${HOST}\` | **ดิสก์:** \`${devpath}\` (S/N: \`${serial:-Unknown}\`)\nตรวจพบ Sector เสียหาย (Pending: ${pending} / Reallocated: ${realloc} / Uncorrectable: ${uncorr}) เสี่ยงข้อมูลสูญหายหากลูกคู่แฝดพังตาม กรุณาเตรียมดิสก์สำรองเพื่อทำ \`zpool replace\` ทันที" \
                    --color red \
                    --field "Host|${HOST}|true" \
                    --field "Device|${devpath}|true" \
                    --field "Model|${model:-Unknown}|true" \
                    --field "Serial Number (S/N)|\`${serial:-Unknown}\`|true" \
                    --field "Capacity|${size:-Unknown}|true" \
                    --field "SMART Status|${health_reason}|true" \
                    --field "Bad/Pending/Uncorr|Pending: ${pending} / Realloc: ${realloc} / Uncorr: ${uncorr}|false" \
                    --field "Tray LED|${led_state}|true"
                echo "$NOW" > "$DISK_CRIT_FILE"
            fi
        else
            # No physical bad sectors -> turn off Locate LED & clear critical lock
            command -v ledctl >/dev/null 2>&1 && ledctl locate_off="$devpath" >/dev/null 2>&1 || true
            rm -f "/var/run/pve_disk_${d}_crit_time" "/var/run/pve_disk_${d}_alert_time"

            # TIER 2: WARNING (CRC / Timeout delta without Bad Sectors)
            STATE_FILE="${SMART_STATE_DIR}/${d}.state"
            if [ ! -f "$STATE_FILE" ]; then
                echo "${crc_err} ${cmd_timeout}" > "$STATE_FILE"
            else
                read -r prev_crc prev_to < "$STATE_FILE" 2>/dev/null || { prev_crc=$crc_err; prev_to=$cmd_timeout; }
                prev_crc=${prev_crc:-0}
                prev_to=${prev_to:-0}
                to_diff=$((cmd_timeout - prev_to))

                if [ "$crc_err" -gt "$prev_crc" ] || [ "$to_diff" -ge 5 ]; then
                    echo "${crc_err} ${cmd_timeout}" > "$STATE_FILE"
                    DISK_WARN_FILE="/var/run/pve_disk_${d}_warn_time"
                    LAST_WARN=0
                    [ -f "$DISK_WARN_FILE" ] && LAST_WARN=$(cat "$DISK_WARN_FILE" 2>/dev/null || echo 0)
                    if [ $((NOW - LAST_WARN)) -ge 43200 ]; then
                        /usr/local/bin/discord-send.sh \
                            --tag \
                            --title "🟡 Disk Warning (สัญญาณรบกวน / ตรวจสอบสายเชื่อมต่อ): ${devpath}" \
                            --desc "**เซิร์ฟเวอร์:** \`${HOST}\` | **ดิสก์:** \`${devpath}\` (S/N: \`${serial:-Unknown}\`)\nพบค่าข้อผิดพลาดการสื่อสารเพิ่มขึ้น (CRC Error / Command Timeout) แต่ **ยังไม่พบ Bad Sector ถาวร (ID 5/197/198 = 0)** แนะนำให้ตรวจสอบสาย SATA/Power, Backplane และรัน \`zpool status -v\` เพื่อดูว่าต้อง \`zpool clear\` หรือไม่" \
                            --color yellow \
                            --field "Host|${HOST}|true" \
                            --field "Device|${devpath}|true" \
                            --field "Serial Number (S/N)|\`${serial:-Unknown}\`|true" \
                            --field "UDMA CRC Errors|${prev_crc} -> ${crc_err}|true" \
                            --field "Command Timeout|${prev_to} -> ${cmd_timeout}|true" \
                            --field "Bad Sectors (5/197/198)|0 / 0 / 0 (จานยังปกติ)|true"
                        echo "$NOW" > "$DISK_WARN_FILE"
                    fi
                fi
            fi
        fi
    done
fi

# ---------------- ZFS READ / WRITE / CKSUM ERROR CHECK (TIER 2 WARNING) ----------------
if command -v zpool >/dev/null 2>&1; then
    while IFS= read -r pool; do
        [ -z "$pool" ] && continue
        ERR_LINES=$(zpool status -P "$pool" 2>/dev/null | awk '
            /^[[:space:]]+\/dev\// || /^[[:space:]]+(mirror|raidz|spare|logs|cache)/ {
                r=$(NF-2); w=$(NF-1); c=$NF;
                if ((r+0 > 0) || (w+0 > 0) || (c+0 > 0)) print $0
            }' || true)
        SIG_FILE="/var/run/pve_zfs_${pool}_err_sig"

        if [ -n "$ERR_LINES" ]; then
            CUR_SIG=$(echo "$ERR_LINES" | md5sum | awk '{print $1}')
            PREV_SIG=""
            [ -f "$SIG_FILE" ] && PREV_SIG=$(cat "$SIG_FILE" 2>/dev/null || true)

            # Only fire Warning if not already alerted for this exact error state and no physical bad sectors triggered Critical
            if [ "$CUR_SIG" != "$PREV_SIG" ] && [ "$ANY_DISK_CRITICAL" -eq 0 ]; then
                /usr/local/bin/discord-send.sh \
                    --tag \
                    --title "🟡 Disk/Pool Warning (อ่าน-เขียนสะดุด / ตรวจสอบการเชื่อมต่อ): พูล ${pool}" \
                    --desc "**เซิร์ฟเวอร์:** \`${HOST}\` | พูล \`${pool}\` พบข้อผิดพลาดในการส่งข้อมูล (ZFS READ/WRITE/CKSUM > 0) แต่ **ยังไม่พบ Bad Sector ถาวร (SMART ID 5/197/198 = 0)** แนะนำให้ตรวจสอบสาย SATA/Power และรัน \`zpool status -v\` เพื่อดูว่าต้อง \`zpool clear\` หรือไม่" \
                    --color yellow \
                    --field "Host|${HOST}|true" \
                    --field "Pool|${pool}|true" \
                    --field "ZFS Error Counters|\`\`\`text\n${ERR_LINES}\n\`\`\`|false"
                echo "$CUR_SIG" > "$SIG_FILE"
            fi
        else
            rm -f "$SIG_FILE"
        fi
    done < <(zpool list -H -o name 2>/dev/null || true)
fi

exit 0
