// Re-score the synthetic set with the extension's own request builder and record how many fine,
// debatable and noise posts get hidden, for the three defaults and for all five tone bubbles.
//   node eval/synthetic/regression.mjs  ->  eval/synthetic/regression.json
import { readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { normaliseSettings, requestFor, verdictsFrom, MODEL } from '../../src/wire.js';

const KEY = process.env.TYPESAFE_API_KEY?.trim() || readFileSync(`${homedir()}/.config/typesafe/api_key`, 'utf8').trim();
const T = JSON.parse(readFileSync('eval/synthetic/tweets.json', 'utf8'));
const lat = [];
async function run(picked) {
  const s = normaliseSettings({ picked, customs: [] });
  const res = {}; let i = 0;
  await Promise.all(Array.from({ length: 10 }, async () => { while (i < T.length) { const t = T[i++];
    const req = requestFor([{ id: t.id, author: t.author, text: t.text, quoted: t.quoted, media: t.media, context: t.context }], s);
    const t0 = performance.now();
    const r = await fetch('https://api.typesafe.ai/v1/systemone', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${KEY}` }, body: JSON.stringify({ ...req.body, model: MODEL }) });
    lat.push(performance.now() - t0);
    res[t.id] = verdictsFrom((await r.json()).answers, req.ids, s)[t.id]; } }));
  const idx = { rage: 'm0', crypto: 'm1', engage: 'm2', hype: 'm3', dunk: 'm4' };
  const on = picked.map((p) => idx[p]);
  const noise = T.filter((t) => on.some((m) => t.labels[m] === 1));
  const fine = T.filter((t) => Object.values(t.labels).every((v) => v === 0));
  const h = (arr) => arr.filter((t) => res[t.id]?.hide).length;
  const posts = T.map((t) => ({ id: t.id, pKeep: res[t.id]?.pKeep ?? null, hide: !!res[t.id]?.hide,
    label: on.some((m) => t.labels[m] === 1) ? 'noise' : Object.values(t.labels).every((v) => v === 0) ? 'fine' : 'debatable' }));
  return { picked, noiseCaught: h(noise), noise: noise.length, fineHidden: h(fine), fine: fine.length, posts };
}
const defaults = await run(['rage', 'crypto', 'engage']);
const tone5 = await run(['rage', 'crypto', 'engage', 'hype', 'dunk']);
lat.sort((a, b) => a - b);
const out = { model: MODEL, at: new Date().toISOString(), defaults, tone5, latencyP50: Math.round(lat[lat.length >> 1]) };
writeFileSync('eval/synthetic/regression.json', JSON.stringify(out, null, 2));
console.log(JSON.stringify({ ...out, defaults: { ...defaults, posts: undefined }, tone5: { ...tone5, posts: undefined } }));
