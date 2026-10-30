#!/bin/bash
# /usr/local/bin/discord-disk-report.sh
# Daily System Health & Storage Report for Proxmox VE
set -eo pipefail

HOST=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')
UPTIME=$(uptime -p 2>/dev/null || uptime)

# 1. CPU Temperature (AMD k10temp / Intel coretemp fallback)
CPU_TEMP=$(sensors 2>/dev/null | grep -iE 'Tctl|Package id 0|CPU Temperature' | head -n 1 | awk '{print $2}' | tr -d '+')
[ -z "$CPU_TEMP" ] && CPU_TEMP="N/A"

# 2. RAM Usage
RAM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
RAM_USED=$((RAM_TOTAL - RAM_AVAIL))
RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))
RAM_USED_GB=$(awk -v u="$RAM_USED" 'BEGIN {printf "%.1f", u/1024}')
RAM_TOTAL_GB=$(awk -v t="$RAM_TOTAL" 'BEGIN {printf "%.1f", t/1024}')
RAM_INFO="${RAM_USED_GB}G / ${RAM_TOTAL_GB}G (${RAM_PCT}%)"

# 3. Root Filesystem (/)
ROOT_INFO=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')
ROOT_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

# 4. ZFS Pool(s) Status
ZFS_SUMMARY=""
if command -v zpool >/dev/null 2>&1; then
    while read -r name size alloc free frag cap dedup health; do
        ZFS_SUMMARY+="$(printf "%-8s: %-6s | Used %s/%s (%s) | Frag %s\n" "$name" "$health" "$alloc" "$size" "$cap" "$frag")"
    done < <(zpool list -H -o name,size,alloc,free,frag,cap,dedup,health 2>/dev/null || true)
fi
[ -z "$ZFS_SUMMARY" ] && ZFS_SUMMARY="No ZFS pools found"

# 5. Disk S.M.A.R.T. and Temperature Status
DISK_REPORT=""
DISKS=(/dev/nvme0n1 /dev/sda /dev/sdb /dev/sdc /dev/sdd)

for d in "${DISKS[@]}"; do
    [ -e "$d" ] || continue

    # Health status
    HEALTH=$(smartctl -H "$d" 2>/dev/null | grep -iE 'test result|overall-health' | awk -F: '{print $2}' | xargs)
    [ -z "$HEALTH" ] && HEALTH="UNKNOWN"

    # Temperature & Bad sectors
    if [[ "$d" =~ "nvme" ]]; then
        TEMP=$(smartctl -A "$d" 2>/dev/null | grep -i '^Temperature:' | awk '{print $2}')
        BAD="0"
    else
        TEMP=$(smartctl -A "$d" 2>/dev/null | grep -iE 'Temperature_Celsius|Airflow_Temperature' | head -n 1 | awk '{for(i=10;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; exit}}')
        BAD=$(smartctl -A "$d" 2>/dev/null | grep -i 'Reallocated_Sector_Ct' | awk '{print $10}')
        [ -z "$BAD" ] && BAD="0"
    fi

    [ -z "$TEMP" ] && TEMP="N/A"
    DISK_REPORT+="$(printf "%-13s | %-6s | Temp: %-2s°C | Bad: %s\n" "$d" "$HEALTH" "$TEMP" "$BAD")\n"
done

# 6. Guest summary
VM_RUNNING=$(qm list 2>/dev/null | awk '$3=="running"' | wc -l)
CT_RUNNING=$(pct list 2>/dev/null | awk '$2=="running"' | wc -l)
GUEST_INFO="VMs: ${VM_RUNNING} running | LXCs: ${CT_RUNNING} running"

# Determine Color: Red if any disk not PASSED, or RAM > 90%, or Root > 85%
COLOR="green"
if echo -e "$DISK_REPORT" | grep -qvE 'PASSED|nvme0n1' && echo -e "$DISK_REPORT" | grep -qiE 'FAILED|UNKNOWN'; then
    COLOR="red"
elif [ "$RAM_PCT" -gt 90 ] || [ "$ROOT_PCT" -gt 85 ]; then
    COLOR="yellow"
fi

/usr/local/bin/discord-send.sh \
    --title "📊 รายงานสถานะประจำวัน (Daily Health Check)" \
    --desc "**เซิร์ฟเวอร์:** \`${HOST}\` | ${UPTIME}\n**เวลาตรวจ:** ${DATE}" \
    --color "$COLOR" \
    --field "CPU Package Temp|🌡️ ${CPU_TEMP}|true" \
    --field "RAM Usage|🧠 ${RAM_INFO}|true" \
    --field "Root Disk (/)|💾 ${ROOT_INFO}|true" \
    --field "ZFS Pool Status|\`\`\`text\n${ZFS_SUMMARY}\`\`\`|false" \
    --field "Storage Disks S.M.A.R.T.|\`\`\`text\n$(echo -e "$DISK_REPORT")\`\`\`|false" \
    --field "Active Guests|⚡ ${GUEST_INFO}|false"