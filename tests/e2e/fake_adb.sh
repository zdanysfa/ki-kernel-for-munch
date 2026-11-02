#!/bin/bash
# Stands in for adb so selftest.sh can drive device_smoke.sh without a phone.
# FAKE_ADB_FAULT picks what is broken: panic, crash, not_ki, reboot, offline.
fault=${FAKE_ADB_FAULT:-}

if [ "$1" = get-state ]; then
    [ "$fault" = offline ] || echo device
    exit 0
fi

case "$*" in
    *"uname -r"*)
        if [ "$fault" = not_ki ]; then echo 4.19.325-stock; else echo 4.19.325-Ki-kernel-v1.6.1; fi
        ;;
    *ki_profile/mode*) echo 1 ;;
    *lru_gen/enabled*) echo 0x0001 ;;
    *scaling_cur_freq*) echo 1804800 ;;
    *battery/temp*) echo 312 ;;
    *battery/status*) echo Discharging ;;
    *boot_id*)
        if [ "$fault" = reboot ]; then cat /proc/sys/kernel/random/uuid; else echo fixed-boot-id; fi
        ;;
    *pstore*)
        echo console-ramoops-0
        [ "$fault" = crash ] && echo dmesg-ramoops-0
        ;;
    *dmesg*)
        echo "[    0.000000] Booting Linux on physical CPU 0x0"
        echo "[    1.000000] qcom,qpnp-power-on: PMIC@SID0: Power-off reason: Triggered from UVLO (Under Voltage Lock Out)"
        [ "$fault" = panic ] && echo "[  100.000000] Kernel panic - not syncing: hung_task: blocked tasks"
        ;;
esac
exit 0
