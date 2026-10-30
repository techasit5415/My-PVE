#!/bin/bash
# /usr/local/bin/discord-boot-notify.sh
# Sends Discord notification when host finishes booting up
set -eo pipefail

# Wait up to 30 seconds for outbound network connectivity
for i in {1..30}; do
    if ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 || curl -s --head https://discord.com >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

HOST=$(hostname)
BOOT_TIME=$(uptime -s 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
KERNEL=$(uname -r)
IP_ADDRS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -n 3 | tr '\n' ', ' | sed 's/,$//')

ZFS_STATUS="All pools healthy"
if command -v zpool >/dev/null 2>&1; then
    ZFS_STATUS=$(zpool status -x 2>/dev/null || true)
fi

# Determine previous shutdown reason
PREV_EVENT=$(last -x reboot shutdown 2>/dev/null | grep -E 'reboot|shutdown|crash' | sed -n '2p')
[ -z "$PREV_EVENT" ] && PREV_EVENT="Unknown / First boot"

/usr/local/bin/discord-send.sh \
    --title "🚀 PVE Server Booted Up Successfully" \
    --desc "**เซิร์ฟเวอร์:** \`${HOST}\` เริ่มต้นระบบเสร็จสมบูรณ์ที่เวลา \`${BOOT_TIME}\`" \
    --color green \
    --field "Host|${HOST}|true" \
    --field "Boot Time|${BOOT_TIME}|true" \
    --field "IP Address|${IP_ADDRS:-Unknown}|true" \
    --field "Kernel|${KERNEL}|true" \
    --field "ZFS Status|${ZFS_STATUS}|true" \
    --field "Previous Event|\`\`\`text\n${PREV_EVENT}\n\`\`\`|false"