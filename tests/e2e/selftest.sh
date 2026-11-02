#!/bin/bash
# Prove the e2e checkers pass good input and, more importantly, reject bad input.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

expect() {
    local want=$1 name=$2 got=0
    shift 2
    "$@" > "$work/output" 2>&1 || got=$?
    if { [ "$want" = pass ] && [ "$got" -eq 0 ]; } || { [ "$want" = fail ] && [ "$got" -ne 0 ]; }; then
        echo "ok   $name"
    else
        echo "FAIL $name (wanted $want, exit $got)"
        cat "$work/output"
        failures=$((failures + 1))
    fi
}

# No real waiting: device_smoke.sh inherits this sleep.
sleep() { :; }
export -f sleep

smoke() {
    ADB="$here/fake_adb.sh" FAKE_ADB_FAULT=$1 IDLE_MINUTES=$2 bash "$here/device_smoke.sh"
}

expect pass "device_smoke: healthy phone" smoke "" 0
expect pass "device_smoke: healthy phone survives idle" smoke "" 1
expect fail "device_smoke: no device" smoke offline 0
expect fail "device_smoke: wrong kernel" smoke not_ki 0
expect fail "device_smoke: panic in log" smoke panic 0
expect fail "device_smoke: crash in pstore" smoke crash 0
expect fail "device_smoke: reboot during idle" smoke reboot 1

debug_tool() {
    ADB="$here/fake_adb.sh" FAKE_ADB_FAULT=$1 KI_DEBUG_OUT="$work/logs" bash "$here/device_debug.sh" "${@:2}"
}

collect_reports_power_off_reason() {
    debug_tool "" collect > "$work/collect_output" || return 1
    grep -q UVLO "$work/collect_output" && [ -f "$work/logs/power_supply.txt" ]
}

expect pass "device_debug: collect reports the power-off reason" collect_reports_power_off_reason
expect pass "device_debug: start" debug_tool "" start
expect pass "device_debug: suspend cycles" debug_tool "" suspend 5
expect fail "device_debug: suspend needs a number" debug_tool "" suspend many
expect fail "device_debug: unknown command" debug_tool "" reboot
expect fail "device_debug: no device" debug_tool offline collect

# A minimal zip: arm64 Image header and version banner.
make_image() {
    {
        head -c 56 /dev/zero
        printf 'ARMd'
        printf 'Linux version 4.19.325-Ki-kernel-v1.6.1 (test)\n'
    } > "$1"
}

make_zip() {
    local name=$1 dir
    dir="$work/$name"
    mkdir -p "$dir/kernels/aosp"
    touch "$dir/anykernel.sh"
    printf '\320\015\376\355' > "$dir/dtb_oc"
    cp "$dir/dtb_oc" "$dir/dtb_stock"
    cp "$dir/dtb_oc" "$dir/kernels/aosp/dtb"
    make_image "$dir/kernels/aosp/Image"
    (cd "$dir" && zip -qr "$work/$name.zip" .)
}

good_config="$repo/tests/kconfig_invariants.txt"
grep -v LRU_GEN "$good_config" > "$work/no_mglru.config"

verify() {
    bash "$here/verify_zip.sh" "$work/$1.zip" "${2:-$good_config}"
}

make_zip good
make_zip with_dtbo
touch "$work/with_dtbo/dtbo.img"
(cd "$work/with_dtbo" && zip -qr "$work/with_dtbo.zip" .)
make_zip bad_image
echo "not an image" > "$work/bad_image/kernels/aosp/Image"
(cd "$work/bad_image" && zip -qr "$work/bad_image.zip" .)
make_zip no_stock
rm "$work/no_stock/dtb_stock"
rm "$work/no_stock.zip"
(cd "$work/no_stock" && zip -qr "$work/no_stock.zip" .)

expect pass "verify_zip: good zip" verify good
expect fail "verify_zip: required config missing" verify good "$work/no_mglru.config"
expect fail "verify_zip: dtbo in zip" verify with_dtbo
expect fail "verify_zip: corrupt Image" verify bad_image
expect fail "verify_zip: dtb_stock missing" verify no_stock

if [ "$failures" -gt 0 ]; then
    echo "selftest: $failures failure(s)"
    exit 1
fi
echo "selftest: ok"
