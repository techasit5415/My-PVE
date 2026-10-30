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
declare -a FIELD_NAMES=()
declare -a FIELD_VALS=()
declare -a FIELD_INLINES=()

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
            # Check if 3-arg format: --field "Name" "Value" ["true/false"]
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
                # Pipe or triple-colon delimited: "Name:::Value:::inline" or "Name|Value|inline"
                raw="$2"
                shift 2
                if [[ "$raw" =~ ::: ]]; then
                    IFS=':::' read -r fname fval finline <<< "$raw"
                else
                    # Split only on first two pipes to allow pipes inside value
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

# Convert any literal \n into real newlines
DESCRIPTION=$(echo -e "$DESCRIPTION")

# Build JSON payload
if [ -n "$CONTENT" ] && [ -z "$TITLE" ] && [ -z "$DESCRIPTION" ]; then
    PAYLOAD=$(jq -n \
        --arg content "$(echo -e "$CONTENT")" \
        --arg username "$USERNAME" \
        --arg avatar "$AVATAR" \
        '{content: $content, username: $username, avatar_url: $avatar}')
else
    # Build fields array safely with jq
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