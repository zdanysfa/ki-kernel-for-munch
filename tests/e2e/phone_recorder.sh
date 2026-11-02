#!/system/bin/sh
# Runs on the phone as root; device_debug.sh installs and starts it.
# Files in /data survive a power loss, so they show what happened before the phone died.
# `sleep` does not wake a suspended phone: a gap in battery.log means it was asleep.
dir=/data/local/tmp/ki_debug
sample_seconds=30
battery=/sys/class/power_supply/battery
bms=/sys/class/power_supply/bms
stats=/sys/power/suspend_stats
rtc_alarm=/sys/class/rtc/rtc0/wakealarm
suspend_seconds=20
awake_seconds=10
unplug_seconds=60

# pid files outlive a reboot, so confirm the pid is still ours before killing it.
stop_previous() {
    for file in recorder.pid logcat.pid; do
        pid=$(cat "$dir/$file" 2>/dev/null)
        [ -n "$pid" ] || continue
        grep -q -e phone_recorder -e logcat "/proc/$pid/cmdline" 2>/dev/null && kill "$pid"
    done
}

# Only these areas: pr_debug everywhere logs every allocation and freezes the phone,
# and techpack/display alone fills the 32 MB log buffer in under two minutes.
enable_debug_logs() {
    mount -t debugfs none /sys/kernel/debug 2>/dev/null
    for area in 'drivers/power/supply/*' 'drivers/input/touchscreen/*'; do
        echo "file $area +p" > /sys/kernel/debug/dynamic_debug/control
    done
}

record() {
    stop_previous
    enable_debug_logs
    echo $$ > "$dir/recorder.pid"
    logcat -b all -v threadtime -f "$dir/logcat.txt" -r 4096 -n 4 &
    echo $! > "$dir/logcat.pid"
    while :; do
        echo "$(date '+%F %T') up=$(cut -d' ' -f1 /proc/uptime) soc=$(cat $battery/capacity) raw=$(cat $bms/capacity_raw) uv=$(cat $battery/voltage_now) ua=$(cat $battery/current_now) temp=$(cat $battery/temp) status=$(cat $battery/status)" >> "$dir/battery.log"
        sleep "$sample_seconds"
    done
}

# Compresses hours of idle resume paths into minutes. No USB: it holds the phone awake.
suspend_cycles() {
    sleep "$unplug_seconds"
    input keyevent 223
    i=1
    while [ "$i" -le "$1" ]; do
        echo 0 > "$rtc_alarm"
        echo "+$suspend_seconds" > "$rtc_alarm"
        if echo mem > /sys/power/state; then result=ok; else result=rejected; fi
        echo "$(date '+%F %T') cycle=$i/$1 $result success=$(cat $stats/success) fail=$(cat $stats/fail)" >> "$dir/suspend.log"
        sleep "$awake_seconds"
        i=$((i + 1))
    done
    echo "$(date '+%F %T') done" >> "$dir/suspend.log"
}

case "$1" in
    record) record ;;
    suspend) suspend_cycles "$2" ;;
esac
