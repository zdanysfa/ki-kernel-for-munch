#!/bin/bash
# Repo checks: script syntax, the balanced defaults, and required Kconfig.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1

failures=0

fail() {
    echo "FAIL: $1"
    failures=$((failures + 1))
}

require_line() {
    local file=$1 line=$2 why=$3
    grep -qxF -- "$line" "$file" || fail "$file: missing '$line' ($why)"
}

for script in build.sh fetch_deps.sh anykernel.sh tests/run.sh tests/static/*.sh tests/e2e/*.sh; do
    bash -n "$script" || fail "$script: bash syntax"
done
for script in ki_optimizer_module/*.sh; do
    sh -n "$script" || fail "$script: sh syntax"
done
node --check ki_optimizer_module/webroot/app.js || fail "app.js: syntax"

cmp -s anykernel.sh anykernel_template/anykernel.sh ||
    fail "anykernel.sh and anykernel_template/anykernel.sh differ"

# With kmemleak on, this floods the log with every allocation and the phone freezes after boot.
grep -q '^DEBUG_CMDLINE=.*dyndbg=' build.sh && fail "build.sh: dyndbg in DEBUG_CMDLINE"

while IFS= read -r line; do
    require_line arch/arm64/configs/munch_defconfig "$line" "tests/kconfig_invariants.txt"
done < tests/kconfig_invariants.txt

# The balance goal: a fresh install has to be safe for daily use.
conf=ki_optimizer_module/ki_optimizer.conf
require_line "$conf" "KI_PROFILE=1" "default profile is Balanced"
require_line "$conf" "MGLRU_MODE=1" "default MGLRU is the stable mode"
require_line "$conf" "BYPASS_CHARGING=0" "bypass charging is opt-in"
require_line drivers/misc/ki_profile.c "int current_profile_mode = KI_PROFILE_BALANCED;" "kernel boots Balanced"
grep -q 'default: Stock Safe Volt' anykernel_template/anykernel.sh ||
    fail "installer no longer defaults to Stock GPU"

# scripts/config ignores unknown symbols, which would silently disable a debug option.
symbols=$(sed -n '/^DEBUG_CONFIG_ON=(/,/^KASAN_CONFIG_ON=/p; /^apply_debug_config()/,/^}/p' build.sh |
    grep -v '^ *#' | grep -oE '\b[A-Z][A-Z0-9_]{3,}\b' | grep -vE '^(DEBUG_CONFIG_ON|KASAN_CONFIG_ON|BUILD_PROFILE|DEBUG_CMDLINE)$' | sort -u)
[ -n "$symbols" ] || fail "build.sh: found no debug symbols"
for symbol in $symbols; do
    git grep -qE "^[[:space:]]*(menu)?config $symbol\$" -- '*Kconfig*' ||
        fail "build.sh: unknown Kconfig symbol $symbol"
done

if [ "$failures" -gt 0 ]; then
    echo "check_repo: $failures failure(s)"
    exit 1
fi
echo "check_repo: ok"
