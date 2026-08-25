#!/usr/bin/env bash
# Trim the Guideline 2.1 hardware demo down to the beats that actually carry the
# proof, so the 20 MiB Cloudflare budget buys a watchable bitrate.
#
# The full take is 300s. Fitting that under 20 MiB forces ~500 kbps at 966x1280,
# which holds up for the large BPM digits but destroys the small iPad text in the
# MyWhoosh pairing screens -- and that text ("Device Connection", the green
# sensor tiles, "Heart Rate Bridge / Streaming to 1 peers") is the single piece of
# evidence Guideline 2.1 asks for. At source resolution the text is perfectly
# legible, so this is a bitrate problem, not a framing problem.
#
# Three segments, ~141s total, which roughly doubles the bitrate:
#   A  Apple Watch worn on the wrist, watch app open   -- the upstream hardware
#   B  iPad pairing, Device Connection, first live BPM -- the pairing process
#   C  phone and MyWhoosh showing the same BPM         -- the payoff
#
# Usage: scripts/trim-hardware-demo.sh [output.mp4]
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="scratchpad/20260818 HRB App Review Guideline 2-1 Hardware Demo.MOV"
OUT="${1:-web/review/hardware-demo.mp4}"
TARGET_MIB=20
AUDIO_K=96
LONG_EDGE=1280

# start:end pairs, seconds, in source timeline
SEGMENTS=(
  "8:32"
  "55:118"
  "246:300"
)

[ -f "$SRC" ] || { echo "missing source: $SRC" >&2; exit 1; }

total=0
for seg in "${SEGMENTS[@]}"; do
  s="${seg%%:*}"; e="${seg##*:}"
  total=$(( total + e - s ))
done

# 2-pass needs a video bitrate that leaves room for the audio track.
budget_bits=$(( TARGET_MIB * 1024 * 1024 * 8 ))
audio_bits=$(( AUDIO_K * 1000 * total ))
vbit=$(( (budget_bits - audio_bits) / total ))

echo "segments : ${SEGMENTS[*]}"
echo "duration : ${total}s (was 300s)"
echo "video    : $(( vbit / 1000 )) kbps  (was 500 kbps)"

# Build the trim/concat filter graph. Doing it in one graph avoids intermediate
# files and keeps A/V in sync across the cuts.
# Pass 1 gets a video-only graph. ffmpeg refuses a graph with an output nobody
# maps, so leaving [ac] dangling behind -an is an error, not a no-op.
vfilter=""; avfilter=""
n=0
for seg in "${SEGMENTS[@]}"; do
  s="${seg%%:*}"; e="${seg##*:}"
  vfilter+="[0:v]trim=${s}:${e},setpts=PTS-STARTPTS[v${n}];"
  avfilter+="[0:v]trim=${s}:${e},setpts=PTS-STARTPTS[v${n}];"
  avfilter+="[0:a]atrim=${s}:${e},asetpts=PTS-STARTPTS[a${n}];"
  n=$(( n + 1 ))
done
for (( i = 0; i < n; i++ )); do vfilter+="[v${i}]"; avfilter+="[v${i}][a${i}]"; done
vfilter+="concat=n=${n}:v=1:a=0[vc];[vc]scale=-2:${LONG_EDGE}:flags=lanczos[v]"
avfilter+="concat=n=${n}:v=1:a=1[vc][ac];[vc]scale=-2:${LONG_EDGE}:flags=lanczos[v]"

PASSLOG="$(mktemp -t hwtrim)"
trap 'rm -f "${PASSLOG}"*' EXIT

echo "pass 1/2 ..."
ffmpeg -y -loglevel error -stats -i "$SRC" \
  -filter_complex "$vfilter" -map "[v]" \
  -c:v libx264 -profile:v high -preset slow -b:v "$vbit" \
  -pass 1 -passlogfile "$PASSLOG" -an -f mp4 /dev/null

echo "pass 2/2 ..."
ffmpeg -y -loglevel error -stats -i "$SRC" \
  -filter_complex "$avfilter" -map "[v]" -map "[ac]" \
  -c:v libx264 -profile:v high -preset slow -b:v "$vbit" \
  -pass 2 -passlogfile "$PASSLOG" \
  -c:a aac -b:a "${AUDIO_K}k" -movflags +faststart "$OUT"

bytes=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")
mib=$(echo "scale=1; $bytes / 1048576" | bc)
echo "out      : $OUT — ${mib} MiB"
# Cloudflare Workers hard-refuses a static asset over 25 MiB.
if [ "$bytes" -gt $(( 25 * 1024 * 1024 )) ]; then
  echo "FAIL: over the 25 MiB Cloudflare limit" >&2; exit 1
fi
