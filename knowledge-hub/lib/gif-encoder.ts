import { execFile } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import type { Recording } from './recorder';

const run = promisify(execFile);

export interface GifProfile { width: number; fps: number; colors: number }

/** Tried in order until the GIF fits under maxBytes. */
export const GIF_PROFILES: GifProfile[] = [
  { width: 960, fps: 10, colors: 128 },
  { width: 800, fps: 8, colors: 96 },
  { width: 640, fps: 8, colors: 64 },
];

export interface EncodedAsset {
  gifPath: string;
  posterPath: string;
  bytes: number;
  width: number;
  fps: number;
  durationMs: number;
  /** Stable fingerprint of what the viewer sees at the end + the narrative. Used to skip unchanged uploads. */
  signature: string;
}

export async function encodeGif(rec: Recording, outDir: string, narrative: string, maxBytes = 2_500_000): Promise<EncodedAsset> {
  const framesDir = path.join(outDir, 'frames');
  fs.mkdirSync(framesDir, { recursive: true });

  // 1. Write frames and an ffconcat list with real per-frame durations (frames only arrive on repaint).
  const lines = ['ffconcat version 1.0'];
  rec.frames.forEach((f, i) => {
    const name = `${String(i).padStart(5, '0')}.jpg`;
    fs.writeFileSync(path.join(framesDir, name), f.data);
    const next = rec.frames[i + 1]?.ts ?? rec.endTs;
    const seconds = Math.max(0.02, (next - f.ts) / 1000);
    lines.push(`file '${name}'`, `duration ${seconds.toFixed(3)}`);
  });
  // The concat demuxer ignores the last duration unless the last file is listed again.
  lines.push(`file '${String(rec.frames.length - 1).padStart(5, '0')}.jpg'`);
  const listPath = path.join(framesDir, 'frames.ffconcat');
  fs.writeFileSync(listPath, lines.join('\n') + '\n');

  // 2. Poster = final frame (what the user should end up seeing).
  const posterPath = path.join(outDir, 'poster.jpg');
  const last = rec.frames[rec.frames.length - 1];
  fs.writeFileSync(posterPath, last.data);

  // 3. Two-pass palette GIF, smallest acceptable profile wins.
  const gifPath = path.join(outDir, 'scenario.gif');
  let used: GifProfile | undefined;
  for (const p of GIF_PROFILES) {
    const vf =
      `fps=${p.fps},scale=${p.width}:-1:flags=lanczos,split[a][b];` +
      `[a]palettegen=max_colors=${p.colors}:stats_mode=diff[pal];` +
      `[b][pal]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle`;
    await run('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', listPath, '-vf', vf, '-loop', '0', gifPath]);
    used = p;
    if (fs.statSync(gifPath).size <= maxBytes) break;
  }
  const bytes = fs.statSync(gifPath).size;
  if (bytes > maxBytes) throw new Error(`kh: GIF is ${bytes} bytes after all profiles; shorten the scenario`);

  fs.rmSync(framesDir, { recursive: true, force: true });

  const signature = crypto.createHash('sha256').update(last.data).update(narrative).digest('hex').slice(0, 16);
  return { gifPath, posterPath, bytes, width: used!.width, fps: used!.fps, durationMs: rec.endTs - rec.startTs, signature };
}
