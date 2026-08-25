#!/usr/bin/env bash
# Upload an already-exported .ipa to App Store Connect.
#
# Identifiers come from apple-project.json — see the comments in that file. It
# is gitignored; apple-project.example.json is the committed template.
#
# Usage:
#   scripts/upload-build.sh [ipa]
#
# The private key must already be at
# ~/.appstoreconnect/private_keys/AuthKey_<key-id>.p8 — altool looks there by
# name and takes no path argument.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$ROOT/apple-project.json"
[ -f "$CFG" ] || { echo "No $CFG — copy apple-project.example.json and fill it in." >&2; exit 1; }

# plutil parses JSON, so this needs no interpreter and no dependencies.
cfg() { plutil -extract "$1" raw -o - "$CFG"; }

KEY_ID="$(cfg appStoreConnect.activeKeyId)"
ISSUER="$(cfg appStoreConnect.issuerId)"
KEYDIR="$(cfg appStoreConnect.privateKeyPath)"
KEYDIR="${KEYDIR/#\~/$HOME}"
KEY="$KEYDIR/AuthKey_${KEY_ID}.p8"
BRAND="$(cfg site.brand)"
SCHEME="$(cfg paths.scheme)"
IPA="${1:-$HOME/Downloads/$BRAND/build/$SCHEME.ipa}"

[ -f "$KEY" ] || { echo "No private key at $KEY" >&2; exit 1; }
[ -f "$IPA" ] || { echo "No ipa at $IPA" >&2; exit 1; }

echo "Key $KEY_ID, issuer $ISSUER"
echo "Validating $(basename "$IPA")"
xcrun altool --validate-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER"

# Only upload once validation is clean. A rejected upload still burns the build
# number, and the number auto-increments per build, so a failed attempt means
# rebuilding rather than retrying.
echo "Uploading"
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER"

echo
echo "Uploaded. Processing takes 10-30 minutes before the build can be selected"
echo "for a version in App Store Connect."
