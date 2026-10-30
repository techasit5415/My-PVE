#!/bin/bash
# /usr/local/bin/vzdump-discord.sh
# Proxmox VZDump Hook Script for Discord Notifications
set -eo pipefail

PHASE="$1"
MODE="$2"
VMID="$3"

HOST=$(hostname)

format_duration() {
    local t=$1
    local min=$((t / 60))
    local sec=$((t % 60))
    if [ $min -gt 0 ]; then
        echo "${min}m ${sec}s"
    else
        echo "${sec}s"
    fi
}

get_vm_name() {
    local vid=$1
    local vtype="${VMTYPE:-qemu}"
    local name=""
    if [ "$vtype" = "lxc" ]; then
        name=$(pct config "$vid" 2>/dev/null | grep -m1 '^hostname:' | awk '{print $2}')
    else
        name=$(qm config "$vid" 2>/dev/null | grep -m1 '^name:' | awk '{print $2}')
    fi
    echo "${name:-Guest-$vid}"
}

case "$PHASE" in
    job-init|job-start)
        # Job started
        ;;

    backup-start)
        # Record start timestamp
        date +%s > "/tmp/vzdump_start_${VMID}.tmp"
        ;;

    backup-end)
        START_TIME=""
        [ -f "/tmp/vzdump_start_${VMID}.tmp" ] && START_TIME=$(cat "/tmp/vzdump_start_${VMID}.tmp")
        rm -f "/tmp/vzdump_start_${VMID}.tmp"

        DURATION_STR="Unknown"
        if [ -n "$START_TIME" ]; then
            ELAPSED=$(( $(date +%s) - START_TIME ))
            DURATION_STR=$(format_duration $ELAPSED)
        fi

        VMNAME=$(get_vm_name "$VMID")
        VTYPE="${VMTYPE:-qemu}"

        SIZE="N/A"
        if [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
            SIZE=$(ls -lh "$TARGET" | awk '{print $5}')
        fi

        TARGET_NAME="N/A"
        [ -n "$TARGET" ] && TARGET_NAME=$(basename "$TARGET")

        /usr/local/bin/discord-send.sh \
            --title "✅ สำรองข้อมูลสำเร็จ: ${VTYPE^^} ${VMID} (${VMNAME})" \
            --desc "**โฮสต์:** \`${HOST}\` | สถานะการสำรองข้อมูลเสร็จสมบูรณ์" \
            --color green \
            --field "Host|${HOST}|true" \
            --field "Guest|${VTYPE^^} ${VMID} (${VMNAME})|true" \
            --field "Storage|${STOREID:-N/A}|true" \
            --field "Mode|${MODE:-snapshot}|true" \
            --field "Duration|${DURATION_STR}|true" \
            --field "Backup Size|${SIZE}|true" \
            --field "File|${TARGET_NAME}|false"
        ;;

    backup-abort)
        START_TIME=""
        [ -f "/tmp/vzdump_start_${VMID}.tmp" ] && START_TIME=$(cat "/tmp/vzdump_start_${VMID}.tmp")
        rm -f "/tmp/vzdump_start_${VMID}.tmp"

        DURATION_STR="Unknown"
        if [ -n "$START_TIME" ]; then
            ELAPSED=$(( $(date +%s) - START_TIME ))
            DURATION_STR=$(format_duration $ELAPSED)
        fi

        VMNAME=$(get_vm_name "$VMID")
        VTYPE="${VMTYPE:-qemu}"

        ERR_LOG="No log available"
        if [ -n "$LOGFILE" ] && [ -f "$LOGFILE" ]; then
            ERR_LOG=$(tail -n 12 "$LOGFILE")
        fi

        REASON="เกิดข้อผิดพลาดในการสำรองข้อมูล"
        if echo "$ERR_LOG" | grep -iqE "no space left|disk full|enospc"; then
            REASON="🚨 พื้นที่จัดเก็บข้อมูลเต็ม (Storage / Disk Full)!"
        elif echo "$ERR_LOG" | grep -iqE "timeout|timed out"; then
            REASON="⏱️ เกิดข้อผิดพลาด Timeout ระหว่างแบ็กอัป"
        elif echo "$ERR_LOG" | grep -iqE "connection refused|offline"; then
            REASON="🔌 พื้นที่ปลายทางไม่สามารถเชื่อมต่อได้ (Storage Offline)"
        fi

        /usr/local/bin/discord-send.sh \
            --title "🚨 สำรองข้อมูลล้มเหลว: ${VTYPE^^} ${VMID} (${VMNAME})" \
            --desc "**คำเตือน:** การสำรองข้อมูลล้มเหลว กรุณาตรวจสอบด่วน!" \
            --color red \
            --field "Host|${HOST}|true" \
            --field "Guest|${VTYPE^^} ${VMID} (${VMNAME})|true" \
            --field "Storage|${STOREID:-N/A}|true" \
            --field "Duration|${DURATION_STR}|true" \
            --field "Probable Cause|${REASON}|false" \
            --field "Error Log Snippet|\`\`\`text\n${ERR_LOG}\n\`\`\`|false"
        ;;

    job-end)
        # Job completed
        ;;

    job-abort)
        /usr/local/bin/discord-send.sh \
            --title "🚨 งานสำรองข้อมูล VZDump ทั้งชุดถูกยกเลิก (Job Aborted)" \
            --desc "**เซิร์ฟเวอร์:** \`${HOST}\` งาน Backup Job ถูกขัดจังหวะหรือไม่สามารถทำงานต่อได้" \
            --color red \
            --field "Host|${HOST}|true" \
            --field "Storage|${STOREID:-N/A}|true"
        ;;
esac

exit 0