#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
source scripts/swift-env.sh
swift build "${meeting_swift_flags[@]}" -c "$configuration"
binary_dir="$(swift build "${meeting_swift_flags[@]}" -c "$configuration" --show-bin-path)"
app="${2:-dist/MeetingRecord.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/MeetingRecord" "$app/Contents/MacOS/MeetingRecord"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/IconSource/LUCIDE-LICENSE "$app/Contents/Resources/LUCIDE-LICENSE"
# SwiftPM dependency bundles (for example AWS CRT resource bundles) must travel with the executable.
for bundle in "$binary_dir"/*.bundle; do
    if [ -d "$bundle" ]; then cp -R "$bundle" "$app/Contents/Resources/"; fi
done
codesign --force --deep --sign - --entitlements Resources/MeetingRecord.entitlements "$app"
printf 'Built %s/%s\n' "$PWD" "$app"
