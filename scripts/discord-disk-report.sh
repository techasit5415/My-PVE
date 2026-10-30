#!/bin/bash
# /usr/local/bin/discord-disk-report.sh
# Daily System Health, Storage & Guests Report for Proxmox VE
set -eo pipefail

HOST=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')
UPTIME=$(uptime -p 2>/dev/null || uptime)
IP_ADDR=$(hostname -I | awk '{print $1}')

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
        ZFS_SUMMARY+=$(printf "%-6s: %-6s | Used %s/%s (%s) | Frag %s\n" "$name" "$health" "$alloc" "$size" "$cap" "$frag")
    done < <(zpool list -H -o name,size,alloc,free,frag,cap,dedup,health 2>/dev/null || true)
fi
[ -z "$ZFS_SUMMARY" ] && ZFS_SUMMARY="No ZFS pools found"

# 5. NVMe System SSD Health
NVME_DEV="/dev/nvme0n1"
NVME_REPORT="No NVMe found"
if [ -e "$NVME_DEV" ]; then
    NVME_HEALTH=$(smartctl -H "$NVME_DEV" 2>/dev/null | grep -iE 'test result|overall-health' | awk -F: '{print $2}' | xargs)
    NVME_TEMP=$(smartctl -A "$NVME_DEV" 2>/dev/null | grep -i '^Temperature:' | awk '{print $2}')
    NVME_USED=$(smartctl -A "$NVME_DEV" 2>/dev/null | grep -i '^Percentage Used:' | awk '{print $3}')
    NVME_SPARE=$(smartctl -A "$NVME_DEV" 2>/dev/null | grep -i '^Available Spare:' | awk '{print $3}')
    NVME_WRITTEN=$(smartctl -A "$NVME_DEV" 2>/dev/null | grep -i '^Data Units Written:' | awk '{print $4, $5}')
    NVME_ERRS=$(smartctl -A "$NVME_DEV" 2>/dev/null | grep -i '^Media and Data Integrity Errors:' | awk '{print $6}')

    [ -z "$NVME_USED" ] && NVME_USED="0%"
    NVME_USED_NUM=$(echo "$NVME_USED" | tr -d '%')
    NVME_REMAINING=$((100 - NVME_USED_NUM))
    [ -z "$NVME_TEMP" ] && NVME_TEMP="N/A"

    NVME_REPORT=$(printf "Health:  %s%% (Wear: %s | Written: %s)\nStatus:  %s | Temp: %s°C | Spare: %s | Errs: %s" \
        "$NVME_REMAINING" "$NVME_USED" "${NVME_WRITTEN:-N/A}" "${NVME_HEALTH:-PASSED}" "$NVME_TEMP" "${NVME_SPARE:-100%}" "${NVME_ERRS:-0}")
fi

# 6. SATA HDDs S.M.A.R.T. Status
SATA_REPORT=""
for d in /dev/sda /dev/sdb /dev/sdc /dev/sdd; do
    [ -e "$d" ] || continue
    HEALTH=$(smartctl -H "$d" 2>/dev/null | grep -iE 'test result|overall-health' | awk -F: '{print $2}' | xargs)
    [ -z "$HEALTH" ] && HEALTH="UNKNOWN"
    TEMP=$(smartctl -A "$d" 2>/dev/null | grep -iE 'Temperature_Celsius|Airflow_Temperature' | head -n 1 | awk '{for(i=10;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; exit}}')
    BAD=$(smartctl -A "$d" 2>/dev/null | grep -i 'Reallocated_Sector_Ct' | awk '{print $10}')
    [ -z "$BAD" ] && BAD="0"
    [ -z "$TEMP" ] && TEMP="N/A"
    SATA_REPORT+=$(printf "%-10s | %-6s | Temp: %-2s°C | Bad: %s\n" "$d" "$HEALTH" "$TEMP" "$BAD")
done

# 7. Virtual Machines (VM) List & Summary
VM_LIST=""
VM_RUN_COUNT=0
VM_STOP_COUNT=0
while read -r vmid name status mem bootdisk pid; do
    [ -z "$vmid" ] && continue
    if [ "$status" = "running" ]; then
        VM_RUN_COUNT=$((VM_RUN_COUNT + 1))
        VM_LIST+=$(printf "🟢 %-4s %-12s (running)\n" "$vmid" "$name")
    else
        VM_STOP_COUNT=$((VM_STOP_COUNT + 1))
        VM_LIST+=$(printf "⚪ %-4s %-12s (stopped)\n" "$vmid" "$name")
    fi
done < <(qm list 2>/dev/null | awk 'NR>1 {print $1, $2, $3, $4, $5, $6}' || true)
[ -z "$VM_LIST" ] && VM_LIST="No VMs configured\n"
VM_SUMMARY=$(printf "%s\`\`\`\n**รวม:** 🟢 %d Running | ⚪ %d Stopped" "$VM_LIST" "$VM_RUN_COUNT" "$VM_STOP_COUNT")

# 8. Containers (LXC CT) List & Summary
CT_LIST=""
CT_RUN_COUNT=0
CT_STOP_COUNT=0
while read -r vmid status lock name; do
    [ -z "$vmid" ] && continue
    if [ "$status" = "running" ]; then
        CT_RUN_COUNT=$((CT_RUN_COUNT + 1))
        CT_LIST+=$(printf "🟢 %-4s %-12s (running)\n" "$vmid" "$name")
    else
        CT_STOP_COUNT=$((CT_STOP_COUNT + 1))
        CT_LIST+=$(printf "⚪ %-4s %-12s (stopped)\n" "$vmid" "$name")
    fi
done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $2, $3, $4}' || true)
[ -z "$CT_LIST" ] && CT_LIST="No Containers configured\n"
CT_SUMMARY=$(printf "%s\`\`\`\n**รวม:** 🟢 %d Running | ⚪ %d Stopped" "$CT_LIST" "$CT_RUN_COUNT" "$CT_STOP_COUNT")

# Color calculation
COLOR="green"
if echo "$SATA_REPORT" | grep -qiE 'FAILED|UNKNOWN'; then
    COLOR="red"
elif [ "$RAM_PCT" -gt 90 ] || [ "$ROOT_PCT" -gt 85 ]; then
    COLOR="yellow"
fi

DESC=$(printf "🖥️ **เซิร์ฟเวอร์:** \`%s\` (%s)\n⏱️ **Uptime:** %s\n⏰ **เวลาตรวจ:** %s" "$HOST" "$IP_ADDR" "$UPTIME" "$DATE")

/usr/local/bin/discord-send.sh \
    --title "📊 รายงานสถานะประจำวัน (Daily Health Check)" \
    --desc "$DESC" \
    --color "$COLOR" \
    --field "🌡️ CPU Temp" "$CPU_TEMP" true \
    --field "🧠 Memory (RAM)" "$RAM_INFO" true \
    --field "💾 Root Disk (/)" "$ROOT_INFO" true \
    --field "⚡ NVMe System SSD (250GB)" "\`\`\`text\n${NVME_REPORT}\n\`\`\`" false \
    --field "🔍 SATA Hard Disks S.M.A.R.T." "\`\`\`text\n${SATA_REPORT}\`\`\`" false \
    --field "🗄️ ZFS Storage Pool" "\`\`\`text\n${ZFS_SUMMARY}\`\`\`" false \
    --field "🖥️ Virtual Machines (VM)" "\`\`\`text\n${VM_SUMMARY}" true \
    --field "📦 Containers (LXC CT)" "\`\`\`text\n${CT_SUMMARY}" true