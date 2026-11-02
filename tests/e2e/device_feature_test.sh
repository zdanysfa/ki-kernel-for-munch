#!/bin/bash
# Guided test of phone features over adb. Each step drives what it can, asks you to do the rest,
# then reports new kernel errors, missed frames and whether the phone rebooted. Needs root.
#   device_feature_test.sh [screen|hotspot|camera|audio|all]
# KI_TEST_AUTO=1 skips the questions. The report lands in debug-logs/, which holds personal data.
set -uo pipefail

ADB=${ADB:-adb}
ADB_TIMEOUT=30
AUTO=${KI_TEST_AUTO:-0}
HOTSPOT_SSID=KiTest
HOTSPOT_PASS=ki$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
HOTSPOT_WAIT_SECONDS=180
SWIPE_ROUNDS=8
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
report=${KI_DEBUG_OUT:-$repo/debug-logs}/feature-$(date +%Y%m%d-%H%M%S).txt
failures=0

mkdir -p "$(dirname "$report")"
exec > >(tee "$report") 2>&1

root() {
    timeout "$ADB_TIMEOUT" "$ADB" shell "su -c '$1'" 2>/dev/null | tr -d '\r'
}

ask() {
    echo ">>> $1"
    [ "$AUTO" = 1 ] || read -r -p ">>> tekan Enter kalau sudah " _ </dev/tty
}

uptime_seconds() {
    root 'cut -d" " -f1 /proc/uptime'
}

hwc_missed() {
    root 'dumpsys SurfaceFlinger' | awk '/HWC missed frame count/ {print $NF}'
}

refresh_rate() {
    root 'dumpsys SurfaceFlinger' | awk '/refresh-rate/ {print $3; exit}'
}

# shellcheck disable=SC2016 # single quotes on purpose: these expand on the phone
kernel_errors_since() {
    root 'dmesg' | awk -v since="$1" '{t=$0; sub(/^\[ */, "", t); if (t + 0 > since + 0) print}' |
        grep -E 'Kernel panic|BUG:|Oops|WARNING: CPU|Internal error|kickoff timed out|underrun|context fault|CAM_ERR|subsystem failure|ADSP_E|hung_task|blocked for more' |
        grep -vE 'include/trace/events|cam_isp_context_debug_register'
}

begin_step() {
    echo
    echo "=== $1"
    step_uptime=$(uptime_seconds)
    step_missed=$(hwc_missed)
}

end_step() {
    local now errors count
    now=$(uptime_seconds)
    if [ -z "$now" ] || awk -v a="$now" -v b="$step_uptime" 'BEGIN {exit !(a + 0 < b + 0)}'; then
        echo "FAIL HP reboot atau adb hilang (uptime $step_uptime lalu '$now')"
        failures=$((failures + 1))
        return
    fi
    errors=$(kernel_errors_since "$step_uptime")
    count=$(printf '%s' "$errors" | grep -c .)
    echo "refresh rate: $(refresh_rate) Hz, HWC missed bertambah: $(($(hwc_missed) - step_missed)), Prime $(root 'cat /sys/devices/system/cpu/cpufreq/policy7/scaling_min_freq /sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq' | tr '\n' ' ')kHz (min max)"
    if [ "$count" -gt 0 ]; then
        echo "FAIL $count error kernel baru:"
        printf '%s\n' "$errors" | cut -c1-120 | head -n 10
        failures=$((failures + 1))
    else
        echo "ok   tidak ada error kernel baru"
    fi
}

test_screen() {
    local round=0
    begin_step "layar: buka Settings, script menggeser layar"
    ask "Buka kunci HP dulu"
    root 'am start -a android.settings.SETTINGS' >/dev/null
    while [ "$round" -lt "$SWIPE_ROUNDS" ]; do
        root 'input swipe 540 1700 540 900 400; input swipe 540 900 540 1700 400'
        round=$((round + 1))
    done
    ask "Geser dan tap sendiri 20 detik. Perhatikan stutter dan touch yang tidak merespons"
    end_step
}

# A client shows up in the ARP table of the hotspot interface.
hotspot_clients() {
    root 'cat /proc/net/arp' | awk '$3 == "0x2" && $6 !~ /^(rmnet|wlan0)/' | wc -l
}

test_hotspot() {
    local waited=0
    begin_step "hotspot"
    root "cmd wifi start-softap $HOTSPOT_SSID wpa2 $HOTSPOT_PASS" | tail -n 1 | cut -c1-80
    echo "Sambungkan HP atau laptop lain: SSID $HOTSPOT_SSID, password $HOTSPOT_PASS"
    while [ "$AUTO" != 1 ] && [ "$waited" -lt "$HOTSPOT_WAIT_SECONDS" ]; do
        [ "$(hotspot_clients)" -gt 0 ] && break
        timeout 5 tail -f /dev/null
        waited=$((waited + 5))
    done
    if [ "$AUTO" = 1 ]; then
        echo "lewati tunggu klien (KI_TEST_AUTO)"
    elif [ "$waited" -ge "$HOTSPOT_WAIT_SECONDS" ]; then
        echo "FAIL tidak ada klien tersambung dalam $HOTSPOT_WAIT_SECONDS detik"
        failures=$((failures + 1))
    else
        echo "ok   klien tersambung setelah $waited detik"
        ask "Buka satu situs dari perangkat itu untuk cek internet"
    fi
    root 'cmd wifi stop-softap' >/dev/null
    end_step
}

test_camera() {
    local server_before server_after
    begin_step "kamera: script membuka kamera, sisanya kamu"
    server_before=$(root 'pidof cameraserver')
    root 'am start -a android.media.action.STILL_IMAGE_CAMERA' >/dev/null
    ask "Gerakkan kamera, ambil foto, pindah kamera depan dan belakang, rekam video 15 detik"
    server_after=$(root 'pidof cameraserver')
    echo "refresh rate saat kamera terbuka: $(refresh_rate) Hz"
    root 'input keyevent 3'
    if [ "$server_before" = "$server_after" ]; then
        echo "ok   cameraserver tidak crash"
    else
        echo "FAIL cameraserver restart ($server_before lalu $server_after)"
        failures=$((failures + 1))
    fi
    end_step
}

test_audio() {
    begin_step "audio"
    ask "Putar musik lewat speaker 20 detik, lalu lewat headset kalau ada. Kabari kalau suaranya aneh"
    end_step
}

case "${1:-all}" in
    screen) test_screen ;;
    hotspot) test_hotspot ;;
    camera) test_camera ;;
    audio) test_audio ;;
    all)
        test_screen
        test_hotspot
        test_camera
        test_audio
        ;;
    *)
        echo "Usage: device_feature_test.sh [screen|hotspot|camera|audio|all]"
        exit 2
        ;;
esac

echo
echo "laporan: $report"
if [ "$failures" -gt 0 ]; then
    echo "gagal: $failures step"
    exit 1
fi
echo "semua step ok"
