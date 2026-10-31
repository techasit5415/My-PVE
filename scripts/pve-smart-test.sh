#!/bin/bash
# /usr/local/bin/pve-smart-test.sh
# Automated SMART Self-Test runner for physical disks
set -uo pipefail

TEST_TYPE="${1:-short}"
if [ "$TEST_TYPE" != "short" ] && [ "$TEST_TYPE" != "long" ]; then
    echo "Usage: $0 [short|long]"
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting SMART $TEST_TYPE self-test on $(hostname)..."

HAS_MEGARAID=$(smartctl --scan 2>/dev/null | grep -c "megaraid" || true)

smartctl --scan 2>/dev/null | while read -r line; do
    [ -z "$line" ] && continue
    dev_str=$(echo "$line" | cut -d'#' -f1 | xargs)
    [ -z "$dev_str" ] && continue

    if [ "$HAS_MEGARAID" -gt 0 ] && echo "$dev_str" | grep -qE '^/dev/sd[a-z] -d scsi'; then
        continue
    fi

    if echo "$dev_str" | grep -qE '^/dev/sr[0-9]'; then
        continue
    fi

    echo "Running: smartctl -t $TEST_TYPE $dev_str"
    smartctl -t "$TEST_TYPE" $dev_str >/dev/null 2>&1 || true
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] SMART $TEST_TYPE tests triggered successfully."