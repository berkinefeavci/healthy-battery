// Adds an ElevenLabs voice-over and music bed to the rendered promo videos.
// Usage: ELEVENLABS_API_KEY=... node promo/audio.mjs [en|tr] [--music path/to/track.mp3]
// Optional: ELEVENLABS_VOICE_ID (or ELEVENLABS_VOICE_ID_EN / _TR) picks the voice.
// Generated clips are cached in promo/out/audio/; delete a file there to regenerate it.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const langs = args.filter(a => a === 'en' || a === 'tr');
if (!langs.length) langs.push('en', 'tr');
const musicArg = args.includes('--music') ? path.resolve(args[args.indexOf('--music') + 1]) : null;

const DURATION = 63;
const KEY = process.env.ELEVENLABS_API_KEY;
const API = 'https://api.elevenlabs.io/v1';
const script = JSON.parse(readFileSync(path.join(dir, 'narration.json'), 'utf8'));
const outDir = path.join(dir, 'out');
const audioDir = path.join(outDir, 'audio');
mkdirSync(audioDir, { recursive: true });

function post(url, body, file) {
  if (!KEY) throw new Error('ELEVENLABS_API_KEY is not set');
  // curl honors the environment's HTTPS proxy and CA bundle; Node's fetch does not.
  const status = execFileSync('curl', ['-sS', '-o', file, '-w', '%{http_code}', '-X', 'POST', url,
    '-H', `xi-api-key: ${KEY}`, '-H', 'Content-Type: application/json', '-H', 'Accept: audio/mpeg',
    '--data-binary', JSON.stringify(body)], { encoding: 'utf8' }).trim();
  if (status !== '200') {
    const msg = readFileSync(file, 'utf8').slice(0, 500);
    execFileSync('rm', ['-f', file]);
    throw new Error(`${url} -> HTTP ${status}: ${msg}`);
  }
}

const duration = file => Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration',
  '-of', 'csv=p=0', file], { encoding: 'utf8' }));

function music() {
  if (musicArg) return musicArg;
  const file = path.join(audioDir, 'music.mp3');
  if (!existsSync(file)) {
    console.log('music: generating');
    post(`${API}/music`, { prompt: script.music_prompt, music_length_ms: DURATION * 1000, force_instrumental: true }, file);
  }
  return file;
}

function voice(lang) {
  const voiceId = process.env[`ELEVENLABS_VOICE_ID_${lang.toUpperCase()}`] || process.env.ELEVENLABS_VOICE_ID || 'JBFqnCBsd6RMkjVDRZzb';
  return script[lang].map((line, i) => {
    const file = path.join(audioDir, `${lang}-${i}.mp3`);
    if (!existsSync(file)) {
      console.log(`${lang}: line ${i + 1}/${script[lang].length}`);
      post(`${API}/text-to-speech/${voiceId}?output_format=mp3_44100_128`, {
        text: line.text, model_id: 'eleven_multilingual_v2', language_code: lang,
        voice_settings: { stability: 0.5, similarity_boost: 0.75, style: 0.25, use_speaker_boost: true }
      }, file);
    }
    return { ...line, file };
  });
}

const bed = music();
for (const lang of langs) {
  const lines = voice(lang);
  const inputs = [], filters = [];
  lines.forEach((l, i) => {
    const end = i + 1 < lines.length ? lines[i + 1].at - 0.15 : DURATION - 0.8;
    const len = duration(l.file);
    // Speed a line up slightly (at most 15%) when it runs into the next one.
    const tempo = Math.min(1.15, Math.max(1, len / (end - l.at)));
    if (len / tempo > end - l.at + 0.05) console.warn(`${lang}: line ${i + 1} overruns by ${(len / tempo - (end - l.at)).toFixed(2)}s`);
    inputs.push('-i', l.file);
    const ms = Math.round(l.at * 1000);
    filters.push(`[${i}:a]aresample=48000,atempo=${tempo.toFixed(3)},adelay=${ms}|${ms}[v${i}]`);
  });
  const n = lines.length;
  inputs.push('-i', bed, '-i', path.join(outDir, `healthy-battery-${lang}.mp4`));
  filters.push(
    `${lines.map((_, i) => `[v${i}]`).join('')}amix=inputs=${n}:normalize=0,apad,atrim=0:${DURATION},asplit=2[vo][sc]`,
    `[${n}:a]aresample=48000,atrim=0:${DURATION},apad,atrim=0:${DURATION},afade=t=in:d=0.4,afade=t=out:st=${DURATION - 3}:d=3,volume=0.5[m]`,
    `[m][sc]sidechaincompress=threshold=0.03:ratio=6:attack=40:release=500[duck]`,
    `[duck][vo]amix=inputs=2:normalize=0,loudnorm=I=-16:TP=-1.5:LRA=11[a]`
  );
  const out = path.join(outDir, `healthy-battery-${lang}-audio.mp4`);
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', ...inputs, '-filter_complex', filters.join(';'),
    '-map', `${n + 1}:v`, '-map', '[a]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-t', String(DURATION),
    '-movflags', '+faststart', out], { stdio: 'inherit' });
  console.log('wrote', out);
}
