#!/usr/bin/env bash
# Build a Release .ipa for sideloading, and attach it to a GitHub release.
#
# The binary is signed with the distribution certificate, which means it will
# not install directly on an arbitrary device — sideloading tools (AltStore,
# Sideloadly, or a paid developer account in Xcode) re-sign the payload with the
# installer's own identity. That is the normal path and the reason a plain
# app-store-shaped ipa is what to publish.
#
# Usage:
#   scripts/xcode/make-sideload-ipa.sh          # build only
#   scripts/xcode/make-sideload-ipa.sh --release  # build, then gh release create

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

CFG="$ROOT/apple-project.json"
cfg() { plutil -extract "$1" raw -o - "$CFG"; }
TEAM="$(cfg team.id)"

# Automatic signing needs to ask App Store Connect for a provisioning profile,
# and by default it asks as whichever account is signed into Xcode. There is
# none here, which surfaces at export rather than archive as a bare
# "Copy failed" — the real line is in the distribution log:
#   Failed to find an account with App Store Connect access for team …
# Passing the same API key the rest of the scripts use removes the dependency
# on Xcode's account list entirely.
KEY_ID="$(cfg appStoreConnect.activeKeyId)"
ISSUER="$(cfg appStoreConnect.issuerId)"
KEYDIR="$(cfg appStoreConnect.privateKeyPath)"
AUTH=(-authenticationKeyPath "${KEYDIR/#\~/$HOME}/AuthKey_${KEY_ID}.p8"
      -authenticationKeyID "$KEY_ID"
      -authenticationKeyIssuerID "$ISSUER")

SCHEME="$(cfg paths.scheme)"
XCODEPROJ="$(cfg paths.xcodeproj)"
APP_NAME="$(cfg app.name)"

OUT="$ROOT/build/sideload"
ARCHIVE="$OUT/$SCHEME.xcarchive"
rm -rf "$OUT"; mkdir -p "$OUT"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM</string>
  <key>uploadSymbols</key><true/>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

"$(dirname "$0")/gen-xcconfig.sh"
xcodegen generate

xcodebuild archive \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${AUTH[@]}"

# Xcode packages the .ipa by shelling out to whichever `rsync` is first on
# PATH. Homebrew's rsync 3.4.x rejects the arguments it is given and the only
# symptom is "error: exportArchive Copy failed" — the rsync line is buried in
# the distribution log. macOS ships openrsync at /usr/bin, which works, so put
# it first for this one command rather than changing anything global.
PATH="/usr/bin:$PATH" \
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$OUT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates "${AUTH[@]}"

IPA="$OUT/$SCHEME.ipa"

# The tag names the artifact, so both numbers are read out of the artifact.
#
# build_number.xcconfig is the wrong source: the preBuildScript rewrites it
# during the archive, so by the time this line runs it holds the number the NEXT
# build will carry, and the tag named a build the ipa does not contain.
# apple-project.json was the wrong source for the version for the same class of
# reason — it was a second copy that could disagree with the shipped bundle.
# MARKETING_VERSION in project.yml is what compiles in; reading it back out of
# the bundle proves what actually shipped rather than restating the input.
#
# The entry is matched at an exact depth. unzip's `*` matches `/`, so a
# Payload/*.app/Info.plist pattern also matches the watch app nested at
# Payload/X.app/Watch/Y.app/Info.plist and would concatenate both plists.
PLIST_ENTRY="$(unzip -Z1 "$IPA" | grep -E '^Payload/[^/]+\.app/Info\.plist$' | head -1)"
if [ -z "$PLIST_ENTRY" ]; then
  echo "cannot find the app Info.plist inside $IPA" >&2
  exit 1
fi
unzip -p "$IPA" "$PLIST_ENTRY" > "$OUT/BuiltInfo.plist"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$OUT/BuiltInfo.plist")"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$OUT/BuiltInfo.plist")"
TAG="v${VERSION}-${BUILD}"

echo
echo "$IPA"
echo "tag would be $TAG"

if [ "${1:-}" = "--release" ]; then
  gh release create "$TAG" "$IPA" \
    --title "$VERSION (build $BUILD)" \
    --notes "Release build of $APP_NAME $VERSION, build $BUILD.

Signed for distribution, so it needs re-signing to install: AltStore, Sideloadly,
or drag it into Xcode with your own developer account. HealthKit and background
Bluetooth do not work under a free provisioning profile — signing needs a paid
Apple Developer account.

The App Store build is the same source at USD 4.99."
fi
