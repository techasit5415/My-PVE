#!/bin/bash
# /usr/local/bin/discord-send.sh
# Universal Discord Notification Sender for Proxmox VE
set -eo pipefail

CONF_FILE="/etc/pve-discord.conf"
if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
fi

WEBHOOK="${DISCORD_WEBHOOK_URL:-}"
USERNAME="${DISCORD_USERNAME:-PVE-Monitor}"
AVATAR="${DISCORD_AVATAR:-}"

if [ -z "$WEBHOOK" ]; then
    echo "ERROR: DISCORD_WEBHOOK_URL is not set in $CONF_FILE" >&2
    exit 1
fi

TITLE=""
DESCRIPTION=""
COLOR=3447003 # Default Blue
FOOTER="$(hostname) • $(date '+%Y-%m-%d %H:%M:%S')"
CONTENT=""
declare -a FIELDS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)
            TITLE="$2"
            shift 2
            ;;
        --desc|--description)
            DESCRIPTION="$2"
            shift 2
            ;;
        --color)
            case "$2" in
                red|critical|danger|error)  COLOR=15158332 ;; # 0xE74C3C
                green|ok|success)            COLOR=3066993  ;; # 0x2ECC71
                yellow|warn|warning)         COLOR=16766720 ;; # 0xFFA500
                orange)                      COLOR=15105570 ;; # 0xE67E22
                blue|info)                   COLOR=3447003  ;; # 0x3498DB
                purple)                      COLOR=10181046 ;; # 0x9B59B6
                [0-9]*)                      COLOR="$2"     ;;
                *)                           COLOR=3447003  ;;
            esac
            shift 2
            ;;
        --field)
            # format: "Name|Value" or "Name|Value|inline"
            FIELDS+=("$2")
            shift 2
            ;;
        --text|--content)
            CONTENT="$2"
            shift 2
            ;;
        --footer)
            FOOTER="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Build JSON payload
if [ -n "$CONTENT" ] && [ -z "$TITLE" ] && [ -z "$DESCRIPTION" ]; then
    PAYLOAD=$(jq -n \
        --arg content "$CONTENT" \
        --arg username "$USERNAME" \
        --arg avatar "$AVATAR" \
        '{content: $content, username: $username, avatar_url: $avatar}')
else
    # Build fields array
    FIELDS_JSON="[]"
    for f in "${FIELDS[@]}"; do
        IFS='|' read -r fname fval finline <<< "$f"
        [ -z "$fname" ] && continue
        is_inline=false
        [ "$finline" = "true" ] && is_inline=true
        FIELDS_JSON=$(echo "$FIELDS_JSON" | jq --arg n "$fname" --arg v "$fval" --argjson i "$is_inline" \
            '. += [{"name": $n, "value": $v, "inline": $i}]')
    done

    EMBED=$(jq -n \
        --arg title "$TITLE" \
        --arg desc "$DESCRIPTION" \
        --argjson color "$COLOR" \
        --arg footer "$FOOTER" \
        --argjson fields "$FIELDS_JSON" \
        '{
            title: (if $title != "" then $title else null end),
            description: (if $desc != "" then $desc else null end),
            color: $color,
            fields: (if ($fields | length) > 0 then $fields else null end),
            footer: { text: $footer },
            timestamp: (now | todate)
        } | del(.[] | select(. == null))')

    PAYLOAD=$(jq -n \
        --arg username "$USERNAME" \
        --arg avatar "$AVATAR" \
        --argjson embed "$EMBED" \
        '{
            username: $username,
            avatar_url: $avatar,
            embeds: [$embed]
        }')
fi

# Send webhook with retry and timeout
curl -s -S --max-time 15 \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$PAYLOAD" \
    "$WEBHOOK" > /dev/null