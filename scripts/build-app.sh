#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    echo "Uso: $0 [release|debug]" >&2
    exit 1
fi
# The native SwiftPM builder copies Metal source; SwiftTerm supports runtime compilation.
swift build --build-system native -c "$configuration"
binary_dir="$(swift build --build-system native -c "$configuration" --show-bin-path)"
app="dist/Homelab.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Homelab" "$app/Contents/MacOS/Homelab"
cp Resources/Info.plist "$app/Contents/Info.plist"
for bundle in "$binary_dir/"*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done
swift scripts/generate-icon.swift "$app/Contents/Resources/AppIcon.icns"
install -m 644 .build/checkouts/SwiftTerm/LICENSE "$app/Contents/Resources/SwiftTerm-LICENSE.txt"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
echo "App pronto: $(pwd)/$app"
