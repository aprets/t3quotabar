#!/bin/bash
# From devbox: build T3QuotaBar on the build Mac (BUILD_HOST, default mbp3), signed, notarized and stapled, with the
# Sparkle appcast that points installed copies at it.
#   scripts/release.sh            → dist/release/T3QuotaBar-macOS-arm64.zip and dist/release/appcast.xml
#   scripts/release.sh --publish  … then a GitHub release marked latest. Installed copies read its appcast.xml at
#                                 releases/latest/download (Info.plist, SUFeedURL) and update to it within a day.
# Signed on the Mac with Flare's Developer ID identity, which lives in its flare-signing keychain
# (localflare apps/flare/scripts/apple-signing.sh) and never leaves it. Notarized from devbox through Flare's
# scripts/asc.ts, whose App Store Connect key stays in /root/.config/flare-apple. The update itself is signed with
# T3QuotaBar's own EdDSA key, in the Mac's t3quotabar-signing keychain (scripts/sparkle-key.sh).
# CFBundleVersion is the build's UTC time, so every release sorts after the last.
set -euo pipefail
host=${BUILD_HOST:-mbp3}
flare=${FLARE_DIR:-/root/Projects/localflare/apps/flare}
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain)" ] || { echo "Commit first: a release is a commit." >&2; exit 1; }
if [ "${1:-}" = --publish ]; then
    git fetch -q origin
    [ -n "$(git branch -r --contains HEAD)" ] || { echo "Push $(git rev-parse --short HEAD) first." >&2; exit 1; }
fi
version=$(date -u +%Y%m%d.%H%M)
tag="v$version"
zip=T3QuotaBar-macOS-arm64.zip
out=dist/release
mkdir -p "$out"
stage=$(mktemp -d); trap 'rm -rf "${stage:?}"' EXIT
git archive HEAD | tar -x -C "$stage"
rsync -a --delete --exclude .build "$stage/" "$host:Projects/t3quotabar-release/"

ssh "$host" zsh -s -- "$version" "$zip" <<'MAC'
set -euo pipefail
cd ~/Projects/t3quotabar-release
bash scripts/test.sh >/dev/null
kc=~/Library/Keychains/flare-signing.keychain-db
security unlock-keychain -p "$(cat ~/Projects/flare-signing/keychain-password)" $kc
trap "security lock-keychain $kc" EXIT # locked again whatever fails: it has no timeout
VERSION=$1 CODE_SIGN_KEYCHAIN=$kc CODE_SIGN_IDENTITY="Developer ID Application: Artur Prets (FY3Q2WA2C4)" bash scripts/build-app.sh >/dev/null
security lock-keychain $kc
ditto -c -k --sequesterRsrc --keepParent dist/T3QuotaBar.app dist/$2
MAC
scp -q "$host:Projects/t3quotabar-release/dist/$zip" "$out/$zip"
bun "$flare/scripts/asc.ts" notarize "$out/$zip"

# Apple's ticket stapled to the app, so Gatekeeper needn't ask Apple at first launch; then zipped again and signed for
# Sparkle. The checks' output is the release's evidence.
enclosure=$(ssh "$host" zsh -s -- "$zip" <<'MAC'
set -euo pipefail
cd ~/Projects/t3quotabar-release/dist
xcrun stapler staple -q T3QuotaBar.app
{ codesign --verify --deep --strict --verbose=2 T3QuotaBar.app; spctl -a -vv T3QuotaBar.app; xcrun stapler validate T3QuotaBar.app; } >&2
spctl -a -vv T3QuotaBar.app 2>&1 | grep -q 'source=Notarized Developer ID'
rm -f $1 && ditto -c -k --sequesterRsrc --keepParent T3QuotaBar.app $1
tools=~/Projects/t3quotabar-sparkle/2.10.1 # Package.swift's Sparkle
[[ -x $tools/bin/sign_update ]] || { mkdir -p $tools && curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz | tar -xJ -C $tools; }
kc=~/Library/Keychains/t3quotabar-signing.keychain-db
security unlock-keychain -p "$(cat ~/Projects/t3quotabar-signing/keychain-password)" $kc
trap "security lock-keychain $kc" EXIT
security find-generic-password -a t3quotabar -s sparkle-ed25519 -w $kc | $tools/bin/sign_update --ed-key-file - $1
MAC
)
scp -q "$host:Projects/t3quotabar-release/dist/$zip" "$out/$zip"
cat > "$out/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<title>T3QuotaBar</title>
<item>
<title>$version</title>
<pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
<sparkle:version>$version</sparkle:version>
<sparkle:shortVersionString>$version</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="https://github.com/aprets/t3quotabar/releases/download/$tag/$zip" $enclosure type="application/octet-stream"/>
</item>
</channel>
</rss>
EOF
ls -l "$out"
if [ "${1:-}" = --publish ]; then
    commit=$(git rev-parse HEAD)
    gh release create "$tag" "$out/$zip" "$out/appcast.xml" --target "$commit" --latest --title "T3QuotaBar $version (${commit:0:7})" \
        --notes "Apple Silicon, macOS 14 or newer. Developer ID signed and notarized. Installed copies update to it by themselves."
fi
