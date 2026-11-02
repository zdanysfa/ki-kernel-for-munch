#!/bin/bash
# Find out why the phone powers off, and how a battery or panel behaves. Needs root on the phone.
#   start        record battery and logcat on the phone until the next reboot, then unplug USB
#   suspend <n>  start, then force <n> suspend cycles after 60 s (about 30 s each)
#   idle <min>   start, then stress the idle memory paths for <min> minutes, also on a charger
#   collect      copy all evidence to debug-logs/<time>/, works on any kernel
# The logs hold personal data: never commit or upload them to a public place.
set -uo pipefail

ADB=${ADB:-adb}
ADB_TIMEOUT=30
COLLECT_TIMEOUT=300
PHONE_DIR=/data/local/tmp/ki_debug
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

root() {
    timeout "$ADB_TIMEOUT" "$ADB" shell "su -c '$1'"
}

install_recorder() {
    timeout "$ADB_TIMEOUT" "$ADB" shell "su -c 'mkdir -p $PHONE_DIR; cat > $PHONE_DIR/phone_recorder.sh'" \
        < "$here/phone_recorder.sh"
}

run_detached() {
    root "nohup sh $PHONE_DIR/phone_recorder.sh $1 >/dev/null 2>&1 &"
}

start() {
    install_recorder || { echo "FAIL cannot install the recorder"; exit 1; }
    run_detached record
    echo "recording to $PHONE_DIR. Unplug USB. It stops at the next reboot, so run start again after one."
}

force_suspend() {
    case "$1" in
        "" | *[!0-9]*) usage ;;
    esac
    start
    run_detached "suspend $1"
    echo "unplug USB now: $1 suspend cycles start in 60 s, about $(($1 / 2 + 1)) minutes in total."
}

force_idle() {
    case "$1" in
        "" | *[!0-9]*) usage ;;
    esac
    start
    run_detached "idle $(($1 * 2))"
    echo "idle stress for $1 minutes, USB or charger may stay plugged. If the phone reboots, that is the bug: collect after boot."
}

capture() {
    timeout "$COLLECT_TIMEOUT" "$ADB" shell "su -c '$2'" > "$out/$1" 2>&1 ||
        echo "note: $1 incomplete, see the file"
}

# shellcheck disable=SC2016 # single quotes on purpose: these expand on the phone
collect() {
    out=${KI_DEBUG_OUT:-$repo/debug-logs/$(date +%Y%m%d-%H%M%S)}
    mkdir -p "$out"

    capture dmesg.txt 'dmesg'
    capture info.txt 'uname -a; cat /proc/cmdline; uptime; for p in ro.product.device ro.build.version.incremental ro.build.version.release ro.boot.bootreason sys.boot.reason sys.boot.reason.last persist.sys.boot.reason.history; do echo "$p=$(getprop $p)"; done'
    capture pstore.txt 'for f in /sys/fs/pstore/*; do echo "== $f"; cat "$f"; done'
    capture power_supply.txt 'for d in /sys/class/power_supply/*; do echo "== $d"; cat "$d/uevent"; done; dumpsys battery'
    capture thermal.txt 'for z in /sys/class/thermal/thermal_zone*; do echo "$(cat "$z/type") $(cat "$z/temp")"; done'
    capture display.txt 'cat /sys/class/drm/card0-DSI-1/panel_info; dumpsys SurfaceFlinger --vsync | grep "ideal period"; dumpsys SurfaceFlinger | grep -E "refresh-rate|missed frame"'
    capture suspend_stats.txt 'mount -t debugfs none /sys/kernel/debug 2>/dev/null; for f in /sys/power/suspend_stats/*; do echo "$f=$(cat "$f")"; done; cat /sys/kernel/debug/wakeup_sources'
    capture kmemleak.txt 'mount -t debugfs none /sys/kernel/debug 2>/dev/null; echo scan > /sys/kernel/debug/kmemleak; cat /sys/kernel/debug/kmemleak'
    capture shutdown.txt 'cat /data/system/shutdown-checkpoints/*; dumpsys dropbox --print SYSTEM_LAST_KMSG | tail -n 500'
    capture logcat_now.txt 'logcat -d -b all -v threadtime'
    capture battery_history.txt "cat $PHONE_DIR/battery.log"
    capture suspend_history.txt "cat $PHONE_DIR/suspend.log"
    capture idle_history.txt "cat $PHONE_DIR/idle.log"
    capture deep_sleep.txt 'cat /sys/power/suspend_stats/success; cat /sys/power/system_sleep/stats; settings get global enable_screen_on_proximity_sensor'
    capture logcat_recorded.txt "cat $PHONE_DIR/logcat.txt*"

    echo "evidence: $out"
    grep -hE 'Power-(on|off) reason' "$out/dmesg.txt" ||
        echo "no PMIC power-on/off reason in dmesg: the boot messages have scrolled away, or the driver did not print them"
    echo "crash records in pstore: $(grep -c '^== .*dmesg-ramoops' "$out/pstore.txt")"
    tail -n 3 "$out/battery_history.txt"
}

usage() {
    echo "Usage: device_debug.sh start | suspend <cycles> | idle <minutes> | collect"
    exit 2
}

[ $# -ge 1 ] || usage
case "$1" in
    start | suspend | idle | collect) ;;
    *) usage ;;
esac

[ "$(timeout "$ADB_TIMEOUT" "$ADB" get-state 2>/dev/null)" = device ] || {
    echo "FAIL no device on adb"
    exit 1
}

case "$1" in
    start) start ;;
    suspend) force_suspend "${2:-}" ;;
    idle) force_idle "${2:-}" ;;
    collect) collect ;;
esac
