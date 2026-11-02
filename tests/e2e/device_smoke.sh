#!/bin/bash
# Check a flashed kernel on the phone over adb. Read-only; needs root on the device.
# IDLE_MINUTES=480 also leaves the phone idle and fails if it rebooted or went dark.
# USB keeps the phone awake, so run over wireless adb to exercise real deep sleep.
set -uo pipefail

ADB=${ADB:-adb}
IDLE_MINUTES=${IDLE_MINUTES:-0}
ADB_TIMEOUT=30
failures=0

pass() { echo "ok   $1"; }

fail() {
    echo "FAIL $1"
    failures=$((failures + 1))
}

root() {
    timeout "$ADB_TIMEOUT" "$ADB" shell "su -c '$1'" | tr -d '\r'
}

check_kernel_version() {
    local release
    release=$(root 'uname -r')
    case "$release" in
        *Ki-kernel*) pass "kernel: $release" ;;
        *) fail "not a Ki-kernel build: '$release'" ;;
    esac
}

check_profile() {
    local mode
    mode=$(root 'cat /sys/kernel/ki_profile/mode')
    case "$mode" in
        0 | 1 | 2) pass "ki_profile mode: $mode (0 battery, 1 balanced, 2 performance)" ;;
        *) fail "ki_profile mode unreadable: '$mode'" ;;
    esac
}

check_mglru() {
    local enabled
    enabled=$(root 'cat /sys/kernel/mm/lru_gen/enabled')
    case "$enabled" in
        "" | 0x0000) fail "MGLRU off: '$enabled'" ;;
        *) pass "MGLRU enabled: $enabled" ;;
    esac
}

check_cpu_clusters() {
    local policy freq
    # SM8250 clusters: silver 0-3, gold 4-6, prime 7.
    for policy in 0 4 7; do
        freq=$(root "cat /sys/devices/system/cpu/cpufreq/policy$policy/scaling_cur_freq")
        case "$freq" in
            "" | 0 | *[!0-9]*) fail "cpu policy$policy not running: '$freq'" ;;
            *) pass "cpu policy$policy: $freq kHz" ;;
        esac
    done
}

check_battery() {
    local temp status
    temp=$(root 'cat /sys/class/power_supply/battery/temp')
    status=$(root 'cat /sys/class/power_supply/battery/status')
    case "$temp" in
        "" | *[!0-9-]*) fail "battery temp unreadable: '$temp'"; return ;;
    esac
    # Tenths of a degree C. Outside 0-60C means a bad reading or a real problem.
    if [ "$temp" -lt 0 ] || [ "$temp" -gt 600 ]; then
        fail "battery temp out of range: $temp"
    else
        pass "battery: $temp (0.1C), $status"
    fi
}

check_kernel_log() {
    local errors
    errors=$(root 'dmesg' | grep -E 'Kernel panic|Oops|BUG: |blocked for more than|soft lockup|hard LOCKUP')
    if [ -n "$errors" ]; then
        fail "kernel log has errors:"
        echo "$errors" | head -20
    else
        pass "kernel log clean"
    fi
}

check_pstore() {
    local crashes
    crashes=$(root 'ls /sys/fs/pstore' | grep '^dmesg-ramoops')
    if [ -n "$crashes" ]; then
        fail "previous boot crashed, see /sys/fs/pstore:"
        echo "$crashes"
    else
        pass "no crash record in pstore"
    fi
}

check_survives_idle() {
    local before after
    before=$(root 'cat /proc/sys/kernel/random/boot_id')
    [ -n "$before" ] || { fail "cannot read boot_id before idle"; return; }

    echo "idling for $IDLE_MINUTES minute(s)..."
    sleep $((IDLE_MINUTES * 60))

    after=$(root 'cat /proc/sys/kernel/random/boot_id')
    if [ -z "$after" ]; then
        fail "phone unreachable after $IDLE_MINUTES minute(s) idle"
    elif [ "$after" != "$before" ]; then
        fail "phone rebooted during idle"
    else
        pass "survived $IDLE_MINUTES minute(s) idle"
    fi
}

[ "$(timeout "$ADB_TIMEOUT" "$ADB" get-state 2>/dev/null)" = device ] || {
    echo "FAIL no device on adb"
    exit 1
}

check_kernel_version
check_profile
check_mglru
check_cpu_clusters
check_battery
check_pstore
[ "$IDLE_MINUTES" -gt 0 ] && check_survives_idle
check_kernel_log

if [ "$failures" -gt 0 ]; then
    echo "device_smoke: $failures failure(s)"
    exit 1
fi
echo "device_smoke: ok"
