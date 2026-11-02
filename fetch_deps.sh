#!/bin/bash
# Fetch the out-of-tree sources behind drivers/kernelsu, fs/nomount and
# security/baseband-guard. Always the newest commit of each default branch, so a
# build can break when upstream changes: the printed hashes record what was used.
set -euo pipefail

cd "$(dirname "$0")"

fetch() {
    local dir=$1 url=$2
    mkdir -p "$dir"
    # init comes first: without its own .git, git -C would act on the kernel repo.
    git -C "$dir" init -q
    # Full history and tags: KernelSU derives its version from them.
    git -C "$dir" fetch -q --tags "$url" HEAD
    git -C "$dir" checkout -qf FETCH_HEAD
    echo "$dir $url $(git -C "$dir" rev-parse HEAD)"
}

# BakaSU only trusts its own, the official and the KowSU manager. Each entry is the
# size and SHA-256 of that manager's v2 signing certificate, taken from its release APK.
add_managers() {
    local table=KernelSU/kernel/manager/apk_sign.c
    local anchor='{ EXPECTED_SIZE_OFFICIAL, EXPECTED_HASH_OFFICIAL },'
    if ! grep -qF "$anchor" "$table"; then
        echo "Error: $table changed upstream, cannot add managers" >&2
        exit 1
    fi
    sed -i "/$anchor/a\\
    { 0x3e6, \"79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7\" }, // KernelSU-Next\\
    { 0x396, \"f415f4ed9435427e1fdf7f1fccd4dbc07b3d6b8751e4dbcec6f19671f427870b\" }, // RKSU\\
    { 0x2cc, \"2d89b50aaf1db013c2b6738f973f48b62ea21a3a8d7216bfec3521065d448458\" }, // FinaSU\\
    { 0x368, \"b9ee6759de4794f954883458b722b97ae6527cb7709a051db9a2348c0eea1e42\" }, // MidoriSU
" "$table"
}

fetch KernelSU https://github.com/Baka-SU/BakaSU
fetch NoMount https://github.com/maxsteeel/nomount
fetch Baseband-guard https://github.com/vc-teahouse/Baseband-guard
add_managers
