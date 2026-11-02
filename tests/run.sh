#!/bin/bash
# Every check that needs neither a kernel build nor a device.
set -euo pipefail

cd "$(dirname "$0")/.."

bash tests/static/check_repo.sh
node --test tests/unit/*.test.mjs
cargo test --quiet --manifest-path ki_daemon/Cargo.toml
bash tests/e2e/selftest.sh

echo "tests/run.sh: all passed"
