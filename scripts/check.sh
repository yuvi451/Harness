#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Use a temporary scratch directory because Finder/file-provider metadata on
# bundles in synced Documents can invalidate ad-hoc XCTest signatures.
HARNESS_SCRATCH="${HARNESS_SCRATCH:-/private/tmp/harness-build}"
swift build --scratch-path "$HARNESS_SCRATCH"
swift test --scratch-path "$HARNESS_SCRATCH"
