#!/bin/bash
# Builds dist/T3QuotaBar.app on a Mac. VERSION sets CFBundleVersion, which Sparkle compares (scripts/release.sh).
# CODE_SIGN_IDENTITY (or .signing-identity) signs it, from CODE_SIGN_KEYCHAIN if set; a real identity adds the
# hardened runtime and a secure timestamp, for notarization. Without one it is ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$PWD/dist/T3QuotaBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp .build/release/T3QuotaBar "$app/Contents/MacOS/"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/T3QuotaBar"
cp -R .build/release/T3QuotaBar_T3QuotaBar.bundle "$app/Contents/Resources/"
# Sparkle's XPC services exist for sandboxed apps; this one isn't, so they go.
cp -R .build/release/Sparkle.framework "$app/Contents/Frameworks/"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
cp Info.plist "$app/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    plutil -replace CFBundleVersion -string "$VERSION" "$app/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
else # a local build: without Sparkle's keys it never replaces itself with the latest release
    plutil -remove SUFeedURL "$app/Contents/Info.plist"
    plutil -remove SUPublicEDKey "$app/Contents/Info.plist"
fi
cp Sources/T3QuotaBar/Resources/AppIcon.icns "$app/Contents/Resources/"
cp LICENSE "$app/Contents/Resources/T3QuotaBar-LICENSE"
identity="${CODE_SIGN_IDENTITY:--}"
if [[ "$identity" == - && -f .signing-identity ]]; then
    identity="$(< .signing-identity)"
fi
options=()
[[ "$identity" == - ]] || options+=(--options runtime --timestamp)
[[ -z "${CODE_SIGN_KEYCHAIN:-}" ]] || options+=(--keychain "$CODE_SIGN_KEYCHAIN")
# Inside out, without --deep, which signs out of order.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for code in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle" "$app"; do
    codesign --force --sign "$identity" ${options[@]+"${options[@]}"} "$code"
done
codesign --verify --deep --strict "$app"
echo "$app"
