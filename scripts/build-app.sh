#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$PWD/dist/T3QuotaBar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/T3QuotaBar "$app/Contents/MacOS/"
cp -R .build/release/T3QuotaBar_T3QuotaBar.bundle "$app/Contents/Resources/"
cp Info.plist "$app/Contents/Info.plist"
identity="${CODE_SIGN_IDENTITY:--}"
if [[ "$identity" == - && -f .signing-identity ]]; then
    identity="$(< .signing-identity)"
fi
codesign --force --deep --sign "$identity" "$app"
echo "$app"
