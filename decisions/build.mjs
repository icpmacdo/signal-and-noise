// Inline the shared tokens and the synthetic data into each decision page.
//   node decisions/build.mjs   ->  decisions/dist/*.html
import { readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs';

const dir = new URL('.', import.meta.url).pathname;
const root = `${dir}..`;
const tweets = JSON.parse(readFileSync(`${root}/eval/synthetic/tweets.json`, 'utf8'));
const scores = JSON.parse(readFileSync(`${root}/eval/synthetic/scores.json`, 'utf8'));
const byId = Object.fromEntries(scores.per.map((s) => [s.id, s]));

const L = (t) => [0, 1, 2, 3, 4].map((j) => t.labels[`m${j}`]);
const data = {
  meta: scores.meta,
  mutes: scores.meta.mutes,
  short: ['Political rage bait', 'Crypto shilling', 'Engagement bait', 'Vague AI hype', 'Dunking'],
  tweets: tweets.filter((t) => byId[t.id]).map((t) => {
    const s = byId[t.id];
    return {
      id: t.id, a: t.author, x: t.text, q: t.quoted || '', m: t.media || [], c: t.context || '',
      k: t.kind, n: t.note || '', l: L(t),
      ch: s.choice.per, cha: s.choice.any, no: s.noul.per, noa: s.noul.any,
      c3: s.choice3.per, c3a: s.choice3.any, rep: s.repeatAny,
    };
  }),
  neighbours: scores.neighbours,
};

const tokens = readFileSync(`${dir}tokens.css`, 'utf8');
mkdirSync(`${dir}dist`, { recursive: true });
for (const f of readdirSync(dir).filter((f) => f.endsWith('.src.html'))) {
  const html = readFileSync(`${dir}${f}`, 'utf8')
    .replace('/*TOKENS*/', () => tokens)
    .replace('/*DATA*/null', () => JSON.stringify(data));
  writeFileSync(`${dir}dist/${f.replace('.src', '')}`, html);
  console.log(`dist/${f.replace('.src', '')}  ${(html.length / 1024).toFixed(0)} KB`);
}
