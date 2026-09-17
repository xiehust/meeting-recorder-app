#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh
swift test "${meeting_swift_flags[@]}" --disable-xctest "$@"
