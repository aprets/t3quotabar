#!/bin/bash
# From devbox, once: T3QuotaBar's Sparkle update key, made on the build Mac (BUILD_HOST, default mbp3).
#   scripts/sparkle-key.sh     makes it and prints the public key for Info.plist (SUPublicEDKey)
# Sparkle's generate_keys keeps the key in the login keychain, which is locked over SSH (-25308). So, like Flare's
# signing identity (localflare apps/flare/scripts/mac-signing.sh), it lives in its own keychain,
# ~/Library/Keychains/t3quotabar-signing.keychain-db, whose password is ~/Projects/t3quotabar-signing/keychain-password.
# The key is made in memory by CryptoKit and goes straight into that keychain; it never touches a file or argv.
# scripts/release.sh reads it from there and pipes it to sign_update. Losing it means installed copies can't update.
set -euo pipefail
ssh "${BUILD_HOST:-mbp3}" zsh -s <<'EOF'
set -euo pipefail
kc=~/Library/Keychains/t3quotabar-signing.keychain-db
dir=~/Projects/t3quotabar-signing
[[ ! -e $kc ]] || { print "Already made: $kc"; exit 1; }
mkdir -p -m 700 $dir
pw=$(openssl rand -hex 24)
print -r -- $pw > $dir/keychain-password; chmod 600 $dir/keychain-password
searched=(${(f)"$(security list-keychains -d user | tr -d '" ')"})
security create-keychain -p $pw $kc
security list-keychains -d user -s $searched # off the search list again: only release.sh reads it, by path
security set-keychain-settings $kc # no timeout: release.sh unlocks and locks it
keys=$(xcrun swift - <<'SWIFT'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)
private=${keys%%$'\n'*} public=${keys##*$'\n'}
print -r -- "add-generic-password -a t3quotabar -s sparkle-ed25519 -w $private $kc" | security -i
security lock-keychain $kc
print "SUPublicEDKey: $public"
EOF
