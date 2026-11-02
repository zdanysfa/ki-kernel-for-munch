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

# A minimal zip: arm64 Image header, version banner, and gzipped ikconfig.
make_image() {
    local config=$1 image=$2
    {
        head -c 56 /dev/zero
        printf 'ARMd'
        printf 'Linux version 4.19.325-Ki-kernel-v1.6.1 (test)\n'
        printf 'IKCFG_ST'
        gzip -c "$config"
        printf 'IKCFG_ED'
    } > "$image"
}

make_zip() {
    local name=$1 config=$2 dir
    dir="$work/$name"
    mkdir -p "$dir/kernels/aosp"
    touch "$dir/anykernel.sh"
    printf '\320\015\376\355' > "$dir/dtb_oc"
    cp "$dir/dtb_oc" "$dir/dtb_stock"
    cp "$dir/dtb_oc" "$dir/kernels/aosp/dtb"
    make_image "$config" "$dir/kernels/aosp/Image"
    (cd "$dir" && zip -qr "$work/$name.zip" .)
}

verify() {
    bash "$here/verify_zip.sh" "$work/$1.zip"
}

good_config="$repo/tests/kconfig_invariants.txt"
grep -v LRU_GEN "$good_config" > "$work/no_mglru.config"

make_zip good "$good_config"
make_zip bad_config "$work/no_mglru.config"
make_zip with_dtbo "$good_config"
touch "$work/with_dtbo/dtbo.img"
(cd "$work/with_dtbo" && zip -qr "$work/with_dtbo.zip" .)
make_zip bad_image "$good_config"
echo "not an image" > "$work/bad_image/kernels/aosp/Image"
(cd "$work/bad_image" && zip -qr "$work/bad_image.zip" .)
make_zip no_stock "$good_config"
rm "$work/no_stock/dtb_stock"
rm "$work/no_stock.zip"
(cd "$work/no_stock" && zip -qr "$work/no_stock.zip" .)

expect pass "verify_zip: good zip" verify good
expect fail "verify_zip: required config missing" verify bad_config
expect fail "verify_zip: dtbo in zip" verify with_dtbo
expect fail "verify_zip: corrupt Image" verify bad_image
expect fail "verify_zip: dtb_stock missing" verify no_stock

if [ "$failures" -gt 0 ]; then
    echo "selftest: $failures failure(s)"
    exit 1
fi
echo "selftest: ok"
