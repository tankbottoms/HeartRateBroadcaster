#!/usr/bin/env bash
# Capture screenshots straight off a USB-connected iPhone, so nothing has to be
# copied, AirDropped or synced anywhere. Navigate the app on the phone, press
# Return here, and the PNG lands in the folder prepare-screenshots.ts reads.
#
# Usage:  scripts/capture-screens.sh [count] [outdir]
#
# Requires libimobiledevice (brew install libimobiledevice) and a phone that has
# been trusted on this Mac. Screen must be unlocked and awake for each capture.

set -euo pipefail

COUNT="${1:-8}"
# The drop folder is named after the project, same as every other script that
# reaches into ~/Downloads, so two projects can share it.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRAND="$(plutil -extract site.brand raw -o - "$ROOT/apple-project.json")"
OUT="${2:-$HOME/Downloads/$BRAND}"

if ! ideviceinfo -k DeviceName >/dev/null 2>&1; then
    echo "No device found. Connect the iPhone by cable, unlock it, and trust this Mac." >&2
    exit 1
fi

echo "Device: $(ideviceinfo -k DeviceName)"
mkdir -p "$OUT"

for i in $(seq 1 "$COUNT"); do
    n=$(printf '%02d' "$i")
    read -r -p "Set up screen ${n} on the phone, then press Return (s to skip, q to stop): " key
    case "$key" in
        q|Q) break ;;
        s|S) continue ;;
    esac
    # The phone must be awake; a locked screen captures as a black frame rather
    # than failing, which is the sort of success that wastes an afternoon.
    idevicescreenshot "$OUT/$n.png" >/dev/null
    echo "  wrote $OUT/$n.png"
done

echo
echo "Captured into $OUT"
echo "Next: bun scripts/prepare-screenshots.ts && bun scripts/publish-press-kit.ts"
