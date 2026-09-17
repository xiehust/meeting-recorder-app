#!/bin/bash
# Source from build/test scripts; all paths are discovered from the selected toolchain.
meeting_swift_flags=()
meeting_default_sdk="$(xcrun --show-sdk-path)"
meeting_sdk26="$(dirname "$meeting_default_sdk")/MacOSX26.sdk"
if [ -d "$meeting_sdk26" ]; then
    # Stay on the product's macOS 26 baseline. A newer beta SDK may require Xcode-only UI macro plugins.
    meeting_swift_flags+=(--sdk "$meeting_sdk26")
fi
meeting_swift_binary="$(xcrun --find swift)"
meeting_testing_plugin="$(dirname "$meeting_swift_binary")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ "$(xcode-select -p)" == */CommandLineTools ]] && [ -f "$meeting_testing_plugin" ]; then
    meeting_swift_flags+=(-Xswiftc -load-plugin-library -Xswiftc "$meeting_testing_plugin")
fi
