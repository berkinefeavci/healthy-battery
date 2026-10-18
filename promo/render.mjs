// Renders promo/video.html to MP4 frame by frame.
// Usage: node promo/render.mjs [en|tr] [--stills 1,5.5,12] [--fps 30]
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const lang = args.find(a => a === 'en' || a === 'tr') || 'en';
const stillsArg = args.includes('--stills') ? args[args.indexOf('--stills') + 1] : null;
const fps = args.includes('--fps') ? Number(args[args.indexOf('--fps') + 1]) : 30;
const outDir = path.join(dir, 'out');
mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
await page.goto('file://' + path.join(dir, 'video.html') + `?render=1&lang=${lang}`);
await page.evaluate(() => window.READY);
const duration = await page.evaluate(() => window.DURATION);

if (stillsArg) {
  for (const s of stillsArg.split(',').map(Number)) {
    await page.evaluate(t => window.renderFrame(t), s);
    await page.screenshot({ path: path.join(outDir, `still-${lang}-${s}.png`) });
  }
  await browser.close();
  process.exit(0);
}

const out = path.join(outDir, `healthy-battery-${lang}.mp4`);
const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'png', '-i', '-',
  '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { stdio: ['pipe', 'inherit', 'inherit'] });
const total = Math.round(duration * fps);
for (let i = 0; i < total; i++) {
  await page.evaluate(t => window.renderFrame(t), i / fps);
  const buf = await page.screenshot({ type: 'png' });
  if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
  if (i % 150 === 0) console.log(`${lang}: ${i}/${total}`);
}
ff.stdin.end();
await new Promise(r => ff.on('close', r));
await browser.close();
console.log('wrote', out);
