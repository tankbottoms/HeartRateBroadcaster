#!/usr/bin/env bash
# Trim + encode the Guideline 2.5.4 background-PiP screen recording.
#
# The 110s source is a 59.93fps screen recording at 1320x2868. It carries three
# things Apple asked for and a lot of dead air between them, so we keep only the
# stretches that carry evidence and drop the rest. Shorter take, more bits per
# frame, and a reviewer who reaches the payoff.
#
# Long edge stays at 1600 rather than the 1280 used for the hardware demo: this
# is screen content with small caption text ("BPM . not connected"), and the
# short duration leaves plenty of bitrate for the extra pixels.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="scratchpad/20260819 HRB App Review Guideline 2-5-4 Background PiP.MP4"
OUT="${1:-web/review/background-pip.mp4}"
TARGET_MIB=20        # Workers refuses a static asset above 25 MiB. Leave headroom.
AUDIO_K=96
LONG_EDGE=1600

# start:end in source seconds.
#   2-40   app foreground -> floating window opened -> swipe to Home Screen,
#          window still alive with the BPM visibly changing
#   72-108 window floating over Safari, then over YouTube playing its own audio,
#          which is the .mixWithOthers claim the reply makes
SEGMENTS=( "2:40" "72:108" )

[ -f "$SRC" ] || { echo "missing source: $SRC" >&2; exit 1; }

total=0
for seg in "${SEGMENTS[@]}"; do
  s="${seg%%:*}"; e="${seg##*:}"
  total=$(( total + e - s ))
done

budget_bits=$(( TARGET_MIB * 1024 * 1024 * 8 ))
audio_bits=$(( AUDIO_K * 1000 * total ))
vbit=$(( (budget_bits - audio_bits) / total ))

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

echo "segments=${n} duration=${total}s video=${vbit}bps audio=${AUDIO_K}k -> $OUT"
mkdir -p "$(dirname "$OUT")"
PASSLOG="$(mktemp -t hrbpip)"

ffmpeg -y -hide_banner -loglevel error -i "$SRC" \
  -filter_complex "$vfilter" -map "[v]" \
  -c:v libx264 -profile:v high -preset slow -b:v "$vbit" \
  -passlogfile "$PASSLOG" -pass 1 -an -f mp4 /dev/null

ffmpeg -y -hide_banner -loglevel error -i "$SRC" \
  -filter_complex "$avfilter" -map "[v]" -map "[ac]" \
  -c:v libx264 -profile:v high -preset slow -b:v "$vbit" \
  -passlogfile "$PASSLOG" -pass 2 \
  -c:a aac -b:a "${AUDIO_K}k" -movflags +faststart "$OUT"

rm -f "${PASSLOG}"*
bytes=$(stat -f %z "$OUT")
echo "wrote $OUT ${bytes} bytes"
[ "$bytes" -lt $(( 25 * 1024 * 1024 )) ] || { echo "over the 25 MiB Workers limit" >&2; exit 1; }
