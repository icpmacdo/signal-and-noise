// Score the synthetic tweet set with Jev (synthetic text only; nothing from the real feed).
// Writes eval/synthetic/scores.json used by the decision pages.
//   node eval/synthetic/score.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { choice, noul } from '../designs.mjs';

const KEY = process.env.TYPESAFE_API_KEY?.trim() || readFileSync(`${homedir()}/.config/typesafe/api_key`, 'utf8').trim();
const mutes = JSON.parse(readFileSync('eval/mutes.json', 'utf8'));
const tweets = JSON.parse(readFileSync('eval/synthetic/tweets.json', 'utf8'));
let tokens = 0, calls = 0, model = null; const lat = [];

async function call(body) {
  for (let a = 0; a < 4; a++) {
    const t0 = performance.now();
    const r = await fetch('https://api.typesafe.ai/v1/systemone', { method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${KEY}` },
      body: JSON.stringify({ ...body, model: 'jev-latest' }) });
    if (r.ok) { const j = await r.json(); lat.push(performance.now() - t0); calls++; model = j.model;
      tokens += (j.usage?.input_tokens || 0) + (j.usage?.output_tokens || 0); return j; }
    if (r.status === 429 || r.status >= 500) { await new Promise((s) => setTimeout(s, 400 * 2 ** a)); continue; }
    throw new Error(`${r.status} ${(await r.text()).slice(0, 200)}`);
  }
  throw new Error('retries exhausted');
}
async function pmap(items, n, fn) {
  const out = new Array(items.length); let i = 0;
  await Promise.all(Array.from({ length: n }, async () => { while (i < items.length) { const k = i++; out[k] = await fn(items[k], k); } }));
  return out;
}
const r2 = (x) => Math.round(x * 1000) / 1000;

// 1. Per-tweet scores, one tweet per call, for each design.
const per = await pmap(tweets, 10, async (t) => {
  const c5 = choice.read((await call(choice.request([t], mutes))).answers, 0, mutes);
  const c3 = choice.read((await call(choice.request([t], mutes.slice(0, 3)))).answers, 0, mutes.slice(0, 3));
  const n5 = noul.read((await call(noul.request([t], mutes))).answers, 0, mutes);
  const again = choice.read((await call(choice.request([t], mutes))).answers, 0, mutes); // repeatability
  return { id: t.id,
    choice: { any: r2(c5.any), per: c5.per.map(r2) },
    choice3: { any: r2(c3.any), per: c3.per.map(r2) },
    noul: { any: r2(n5.any), per: n5.per.map(r2) },
    repeatAny: r2(again.any) };
});

// 2. Neighbours: the same borderline tweet judged inside batches of 10 with different company.
const clean = tweets.filter((t) => t.kind === 'clean');
const loud = tweets.filter((t) => t.kind === 'clear');
let seed = 7; const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const pick = (arr, n) => { const a = [...arr]; for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a.slice(0, n); };
const border = tweets.filter((t) => t.kind === 'borderline').slice(0, 40);
const neighbours = await pmap(border, 8, async (t) => {
  const res = {};
  for (const [name, comp] of [['loud', () => pick(loud, 9)], ['clean', () => pick(clean, 9)], ['mixed', () => pick([...loud, ...clean], 9)]]) {
    const vals = [];
    for (let s = 0; s < 2; s++) {
      const batch = [...comp(), t];
      const j = await call(choice.request(batch, mutes));
      vals.push(r2(choice.read(j.answers, 9, mutes).any));
    }
    res[name] = vals;
  }
  return { id: t.id, ...res };
});

lat.sort((a, b) => a - b);
const meta = { model, calls, tokens, latencyP50: Math.round(lat[lat.length >> 1]), latencyP95: Math.round(lat[Math.floor(lat.length * 0.95)]),
  scoredAt: new Date().toISOString(), mutes };
writeFileSync('eval/synthetic/scores.json', JSON.stringify({ meta, per, neighbours }));
console.log(JSON.stringify(meta));
