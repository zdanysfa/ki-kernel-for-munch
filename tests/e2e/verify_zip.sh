#!/bin/bash
# Inspect a flashable zip: layout, image and dtb headers, and the config inside
# the kernel. Shows the build is what we meant to ship, not that it boots.
set -uo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: verify_zip.sh <flashable.zip>"
    exit 2
fi

zip_path=$1
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
    echo "FAIL: $1"
    failures=$((failures + 1))
}

magic() {
    od -An -tx1 -j "$2" -N 4 "$1" | tr -d ' \n'
}

check_dtb() {
    [ -f "$1" ] || { fail "missing ${1#"$work"/}"; return; }
    [ "$(magic "$1" 0)" = d00dfeed ] || fail "${1#"$work"/}: not a dtb"
}

check_image() {
    local image=$1 config
    [ "$(magic "$image" 56)" = 41524d64 ] || { fail "${image#"$work"/}: not an arm64 Image"; return; }
    grep -aqE 'Linux version 4\.19\.[0-9]+-Ki-kernel' "$image" ||
        fail "${image#"$work"/}: missing Ki-kernel version banner"

    config="$work/ikconfig"
    if ! "$repo/scripts/extract-ikconfig" "$image" > "$config" 2>/dev/null; then
        fail "${image#"$work"/}: cannot extract ikconfig"
        return
    fi
    while IFS= read -r line; do
        grep -qxF -- "$line" "$config" || fail "${image#"$work"/}: config lacks '$line'"
    done < "$repo/tests/kconfig_invariants.txt"
}

if ! unzip -q "$zip_path" -d "$work"; then
    echo "FAIL: cannot unzip $zip_path"
    exit 1
fi

[ -f "$work/anykernel.sh" ] || fail "missing anykernel.sh"
check_dtb "$work/dtb_oc"
check_dtb "$work/dtb_stock"
# dtbo stays out: flashing it would replace the ROM's panel and touch overlays.
[ -z "$(find "$work" -name 'dtbo*.img')" ] || fail "zip must not contain dtbo"

images=0
for image in "$work"/kernels/*/Image; do
    [ -f "$image" ] || continue
    images=$((images + 1))
    check_image "$image"
    check_dtb "$(dirname "$image")/dtb"
done
[ "$images" -gt 0 ] || fail "no kernels/*/Image in zip"

if [ "$failures" -gt 0 ]; then
    echo "verify_zip: $failures failure(s)"
    exit 1
fi
echo "verify_zip: ok ($images image(s))"
