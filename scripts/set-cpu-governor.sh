#!/bin/bash
# /usr/local/bin/set-cpu-governor.sh
# Sets AMD P-State EPP Governor to powersave + balance_performance

for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    if [ -f "$gov" ]; then
        echo "powersave" > "$gov" 2>/dev/null || true
    fi
done

for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    if [ -f "$epp" ]; then
        echo "balance_performance" > "$epp" 2>/dev/null || true
    fi
done

logger -t pve-cpu-governor "Configured CPU scaling governor to powersave with balance_performance EPP"