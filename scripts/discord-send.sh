#!/bin/bash
# /usr/local/bin/discord-send.sh
# Universal Discord Notification Sender for Proxmox VE
set -eo pipefail

CONF_FILE="/etc/pve-discord.conf"
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
fi

WEBHOOK="${DISCORD_WEBHOOK_URL:-}"
USERNAME="${DISCORD_USERNAME:-PVE-Monitor}"
AVATAR="${DISCORD_AVATAR:-}"
GLOBAL_TAG="${DISCORD_TAG:-}"

TITLE=""
DESCRIPTION=""
COLOR=3447003 # Default Blue
FOOTER="$(hostname) • $(date '+%Y-%m-%d %H:%M:%S')"
CONTENT=""
TAG_USER=""
declare -a FIELD_NAMES=()
declare -a FIELD_VALS=()
declare -a FIELD_INLINES=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --webhook)
            WEBHOOK="$2"
            shift 2
            ;;
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
        --tag|--mention)
            if [ -n "$2" ] && [[ ! "$2" =~ ^-- ]]; then
                TAG_USER="$2"
                shift 2
            else
                TAG_USER="${GLOBAL_TAG:-}"
                shift 1
            fi
            ;;
        --field)
            if [ $# -ge 3 ] && [[ ! "$3" =~ ^-- ]] && [[ ! "$2" =~ [\|] ]] && [[ ! "$2" =~ ::: ]]; then
                fname="$2"
                fval="$3"
                finline="false"
                shift 3
                if [ $# -ge 1 ] && [[ "$1" =~ ^(true|false)$ ]]; then
                    finline="$1"
                    shift 1
                fi
                FIELD_NAMES+=("$fname")
                FIELD_VALS+=("$fval")
                FIELD_INLINES+=("$finline")
            else
                raw="$2"
                shift 2
                if [[ "$raw" =~ ::: ]]; then
                    IFS=':::' read -r fname fval finline <<< "$raw"
                else
                    fname="${raw%%|*}"
                    rest="${raw#*|}"
                    if [[ "$rest" =~ \|(true|false)$ ]]; then
                        finline="${rest##*|}"
                        fval="${rest%|*}"
                    else
                        finline="false"
                        fval="$rest"
                    fi
                fi
                FIELD_NAMES+=("$fname")
                FIELD_VALS+=("$fval")
                FIELD_INLINES+=("${finline:-false}")
            fi
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

if [ -z "$WEBHOOK" ]; then
    echo "ERROR: Webhook URL is not set" >&2
    exit 1
fi

DESCRIPTION=$(echo -e "$DESCRIPTION")

FORMATTED_TAG=""
if [ -n "$TAG_USER" ]; then
    if [[ "$TAG_USER" == \<@*\> ]]; then
        FORMATTED_TAG="$TAG_USER"
    elif [[ "$TAG_USER" =~ ^[0-9]+$ ]]; then
        FORMATTED_TAG="<@${TAG_USER}>"
    elif [[ "$TAG_USER" == @* ]]; then
        FORMATTED_TAG="$TAG_USER"
    else
        FORMATTED_TAG="@${TAG_USER}"
    fi
fi

if [ -n "$CONTENT" ] && [ -z "$TITLE" ] && [ -z "$DESCRIPTION" ]; then
    FINAL_CONTENT="$(echo -e "$CONTENT")"
    [ -n "$FORMATTED_TAG" ] && FINAL_CONTENT="${FORMATTED_TAG} ${FINAL_CONTENT}"
    PAYLOAD=$(jq -n \
        --arg content "$FINAL_CONTENT" \
        --arg username "$USERNAME" \
        --arg avatar "$AVATAR" \
        '{content: $content, username: $username, avatar_url: $avatar}')
else
    FIELDS_JSON="[]"
    for i in "${!FIELD_NAMES[@]}"; do
        fn="${FIELD_NAMES[$i]}"
        fv=$(echo -e "${FIELD_VALS[$i]}")
        fi_val="${FIELD_INLINES[$i]}"
        is_inline=false
        [ "$fi_val" = "true" ] && is_inline=true

        FIELDS_JSON=$(echo "$FIELDS_JSON" | jq \
            --arg n "$fn" \
            --arg v "$fv" \
            --argjson inl "$is_inline" \
            '. += [{"name": $n, "value": $v, "inline": $inl}]')
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
        --arg content "$FORMATTED_TAG" \
        --argjson embed "$EMBED" \
        '{
            username: $username,
            avatar_url: $avatar,
            content: (if $content != "" then $content else null end),
            embeds: [$embed]
        } | del(.[] | select(. == null))')
fi

curl -s -S --max-time 15 \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$PAYLOAD" \
    "$WEBHOOK" > /dev/null
