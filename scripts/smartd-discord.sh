#!/bin/bash
# /usr/local/bin/smartd-discord.sh
# SMART alert script triggered by smartd (-M exec)
set -eo pipefail

BODY=""
if [ ! -t 0 ]; then
    BODY=$(cat)
fi

DEVICE="${SMARTD_DEVICE:-Unknown Device}"
FAILTYPE="${SMARTD_FAILTYPE:-General Warning}"
MESSAGE="${SMARTD_MESSAGE:-No specific message provided}"
DEVSTRING="${SMARTD_DEVICESTRING:-Unknown}"
HOST=$(hostname)

# Determine severity and color
COLOR="red"
TITLE="🚨 S.M.A.R.T. Alert: ตรวจพบปัญหาฮาร์ดแวร์ดิสก์!"

if [ "$FAILTYPE" = "EmailTest" ]; then
    COLOR="blue"
    TITLE="🧪 S.M.A.R.T. Test: ทดสอบระบบแจ้งเตือนสำเร็จ"
elif [ "$FAILTYPE" = "Temperature" ]; then
    COLOR="orange"
    TITLE="🌡️ S.M.A.R.T. Warning: อุณหภูมิดิสก์เกินเกณฑ์กำหนด"
fi

# Trim body snippet to avoid Discord limits
SNIPPET=$(echo "$BODY" | head -n 12)
if [ -n "$SNIPPET" ]; then
    SNIPPET_FIELD="SMART Details|\`\`\`text\n${SNIPPET}\n\`\`\`|false"
else
    SNIPPET_FIELD="SMART Details|None|false"
fi

/usr/local/bin/discord-send.sh \
    --tag \
    --title "$TITLE" \
    --desc "**เซิร์ฟเวอร์:** \`${HOST}\` พบความผิดปกติของดิสก์ กรุณาตรวจสอบทันที!" \
    --color "$COLOR" \
    --field "Device|${DEVICE}|true" \
    --field "Failure Type|${FAILTYPE}|true" \
    --field "Disk Model|${DEVSTRING}|false" \
    --field "Alert Message|${MESSAGE}|false" \
    --field "$SNIPPET_FIELD"