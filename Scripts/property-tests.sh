#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# BOUTIQUE_SWIFT may point to an isolated Swift.org toolchain. Xcode 26 also works.
SWIFT_BIN="${BOUTIQUE_SWIFT:-swift}"
export BOUTIQUE_TEST_REVISION="$(git rev-parse HEAD)"
exec "$SWIFT_BIN" test "$@"
