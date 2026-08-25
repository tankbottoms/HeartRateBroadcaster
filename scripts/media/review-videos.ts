#!/usr/bin/env bun
/**
 * Prepare the two App Review demo videos for hosting, and pull keyframes so the
 * footage can be checked before it is sent to Apple.
 *
 * Two things make raw phone footage unusable as-is.
 *
 * Cloudflare's static-asset Worker refuses any single file over 25 MiB, and a
 * 90-second 4K clip off an iPhone is several hundred. So each video is
 * re-encoded to a bitrate computed from its own duration to land under the
 * budget below, rather than to a fixed bitrate that would overshoot on a long
 * take and waste quality on a short one.
 *
 * And HEVC in a .mov is what the phone records but not what every browser
 * plays. App Review will open these links in whatever they have; H.264 baseline
 * in an MP4 with the moov atom moved to the front is the version that plays
 * everywhere and starts before it has finished downloading.
 *
 *   bun scripts/review-videos.ts --hardware ~/Desktop/IMG_1234.mov \
 *                                --pip      ~/Desktop/IMG_1235.mov
 *
 * Either flag may be omitted to process just one. Output goes to web/review/,
 * which site.ts copies to dist/review/ and robots.txt disallows.
 */
import { existsSync, mkdirSync, rmSync, statSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { $ } from "bun";

const ROOT = resolve(import.meta.dir, "..", "..");
const OUT_DIR = join(ROOT, "web/review");
const FRAME_DIR = join(ROOT, "build/review-frames");

// 20 MiB, not 25. The limit is a hard refusal at deploy time and the encoder
// only approximates the bitrate it is given, so the headroom is the difference
// between "deploys" and "deploys most of the time".
const TARGET_BYTES = 20 * 1024 * 1024;
const AUDIO_BITRATE = 96_000;
// Above this, extra bitrate buys nothing a reviewer will notice on a phone
// screen recording, and the file may as well be smaller.
const MAX_VIDEO_BITRATE = 4_000_000;
// Long edge. Enough to read a two-digit BPM and a sensor-list row; small enough
// that a 90-second take fits the budget with room over.
const LONG_EDGE = 1280;
const FRAMES = 12;

type Job = { flag: string; name: string; label: string };
const JOBS: Job[] = [
  { flag: "--hardware", name: "hardware-demo", label: "Guideline 2.1 — hardware demo (filmed)" },
  { flag: "--pip", name: "background-pip", label: "Guideline 2.5.4 — PiP in background (screen recording)" },
];

const argv = process.argv.slice(2);
const arg = (flag: string) => {
  const i = argv.indexOf(flag);
  return i === -1 ? undefined : argv[i + 1];
};

const requested = JOBS.map((j) => ({ ...j, src: arg(j.flag) })).filter((j) => j.src);
if (requested.length === 0) {
  console.error("nothing to do. Pass --hardware <file> and/or --pip <file>.");
  process.exit(1);
}

mkdirSync(OUT_DIR, { recursive: true });
mkdirSync(FRAME_DIR, { recursive: true });

const mib = (n: number) => `${(n / 1024 / 1024).toFixed(1)} MiB`;

for (const job of requested) {
  const src = resolve(job.src!);
  if (!existsSync(src)) {
    console.error(`[SKIP] ${job.flag}: no such file — ${src}`);
    continue;
  }

  const probe = await $`ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,codec_name,r_frame_rate \
    -show_entries format=duration,size \
    -of default=noprint_wrappers=1 ${src}`.text();
  const field = (k: string) => probe.match(new RegExp(`^${k}=(.+)$`, "m"))?.[1]?.trim();

  const duration = Number(field("duration") ?? 0);
  const width = Number(field("width") ?? 0);
  const height = Number(field("height") ?? 0);
  if (!duration || !width) {
    console.error(`[SKIP] ${basename(src)}: ffprobe found no video stream`);
    continue;
  }

  console.log(`\n=== ${job.label}`);
  console.log(`  source   ${basename(src)}`);
  console.log(`  in       ${width}x${height} ${field("codec_name")} ${duration.toFixed(1)}s ${mib(statSync(src).size)}`);

  // Duration is what decides the bitrate, so a longer take degrades rather than
  // blowing the budget.
  const budget = Math.floor((TARGET_BYTES * 8) / duration) - AUDIO_BITRATE;
  const videoBitrate = Math.max(500_000, Math.min(MAX_VIDEO_BITRATE, budget));
  if (budget < 500_000) {
    console.log(`  WARNING  ${duration.toFixed(0)}s cannot fit ${mib(TARGET_BYTES)} at a watchable bitrate.`);
    console.log(`           Trim the take, or host this one off the Worker.`);
  }

  // Portrait phone footage must stay portrait. Scaling the long edge rather
  // than "width" is the difference between a readable BPM and a letterboxed
  // strip; -2 keeps the other edge even, which H.264 requires.
  const scale = width >= height ? `scale=${LONG_EDGE}:-2` : `scale=-2:${LONG_EDGE}`;
  const dest = join(OUT_DIR, `${job.name}.mp4`);

  console.log(`  encoding ${(videoBitrate / 1000).toFixed(0)} kbps video, ${scale}`);
  await $`ffmpeg -y -loglevel error -i ${src} \
    -vf ${scale} -c:v libx264 -profile:v high -preset slow \
    -b:v ${videoBitrate} -maxrate ${Math.floor(videoBitrate * 1.3)} -bufsize ${videoBitrate * 2} \
    -pix_fmt yuv420p -c:a aac -b:a ${AUDIO_BITRATE} -movflags +faststart ${dest}`;

  const outSize = statSync(dest).size;
  const verdict = outSize > 25 * 1024 * 1024 ? "OVER THE 25 MiB WORKER LIMIT" : "ok";
  console.log(`  out      ${dest.replace(ROOT + "/", "")} — ${mib(outSize)} (${verdict})`);

  // Evenly spaced stills rather than ffmpeg's scene detection: the question
  // being asked of these is "did every required step get filmed", which is a
  // question about the whole timeline, not about where the cuts are.
  const frames = join(FRAME_DIR, job.name);
  rmSync(frames, { recursive: true, force: true });
  mkdirSync(frames, { recursive: true });
  const step = duration / (FRAMES + 1);
  for (let i = 1; i <= FRAMES; i++) {
    const t = (step * i).toFixed(2);
    await $`ffmpeg -y -loglevel error -ss ${t} -i ${dest} -frames:v 1 \
      -vf scale=720:-2 -q:v 3 ${join(frames, `${String(i).padStart(2, "0")}-t${t}s.jpg`)}`;
  }
  console.log(`  frames   ${FRAMES} stills in ${frames.replace(ROOT + "/", "")}`);
}

console.log(`\nNext: have the frames checked, then`);
console.log(`  bun scripts/site.ts && (cd web && bunx wrangler deploy)`);
