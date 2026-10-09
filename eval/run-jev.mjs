// Score the pool with one design. Resumable: rows already in the output file are skipped.
//   node eval/run-jev.mjs choice|noul|choice10 [concurrency=12]
import { readFileSync, appendFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { choice, noul } from './designs.mjs';

const which = process.argv[2];
const CONC = Number(process.argv[3] || 12);
const design = { choice, noul, choice10: choice }[which];
const batch = which === 'choice10' ? 10 : 1;
const KEY = process.env.TYPESAFE_API_KEY?.trim() || readFileSync(`${homedir()}/.config/typesafe/api_key`, 'utf8').trim();
const mutes = JSON.parse(readFileSync('eval/mutes.json', 'utf8'));
const pool = readFileSync('eval/data/pool.ndjson', 'utf8').trim().split('\n').map((l) => JSON.parse(l));
const out = `eval/data/jev-${which}.ndjson`;
const done = new Set(existsSync(out) ? readFileSync(out, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l).id) : []);
const todo = pool.filter((t) => !done.has(t.id));
const groups = [];
for (let i = 0; i < todo.length; i += batch) groups.push(todo.slice(i, i + batch));

let tokens = 0, calls = 0, failed = 0; const lat = [];
async function call(body) {
  for (let attempt = 0; attempt < 4; attempt++) {
    const t0 = performance.now();
    const r = await fetch('https://api.typesafe.ai/v1/systemone', { method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${KEY}` },
      body: JSON.stringify({ ...body, model: 'jev-latest' }) });
    if (r.ok) { const j = await r.json(); lat.push(performance.now() - t0); return j; }
    if (r.status === 429 || r.status >= 500) { await new Promise((s) => setTimeout(s, 500 * 2 ** attempt)); continue; }
    throw new Error(`${r.status} ${(await r.text()).slice(0, 200)}`);
  }
  throw new Error('gave up after retries');
}
async function worker() {
  while (groups.length) {
    const g = groups.shift();
    try {
      const j = await call(design.request(g, mutes));
      calls++; tokens += (j.usage?.input_tokens || 0) + (j.usage?.output_tokens || 0);
      const rows = g.map((t, i) => ({ id: t.id, model: j.model, ...design.read(j.answers, i, mutes) })).filter((r) => r.per);
      if (rows.length) appendFileSync(out, rows.map((r) => JSON.stringify(r)).join('\n') + '\n');
    } catch (e) { failed++; if (failed < 5) console.error(e.message); }
    if (calls % 200 === 0 && calls) process.stdout.write(`${calls} calls…\n`);
  }
}
const t0 = Date.now();
await Promise.all(Array.from({ length: CONC }, worker));
lat.sort((a, b) => a - b);
console.log(`${which}: ${calls} calls, ${failed} failed, ${tokens} tokens, ${((Date.now() - t0) / 1000).toFixed(0)} s, `
  + `latency p50 ${Math.round(lat[lat.length >> 1])} ms p95 ${Math.round(lat[Math.floor(lat.length * 0.95)])} ms`);
