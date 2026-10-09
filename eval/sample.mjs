// Draw a seeded random pool of tweets from Ian's real home feed (x-bookmark-exporter's export)
// and shape each one exactly the way the content script reads it off X's page.
//   node eval/sample.mjs [size=4000]
import { readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';

const SRC = `${homedir()}/code/x-bookmark-exporter/out/home/tweets.ndjson`;
const SIZE = Number(process.argv[2] || 4000);
const OWN = new Set(['dumbfook']);

// mulberry32: deterministic so the pool can be rebuilt bit for bit.
let seed = 20261008;
const rand = () => { seed |= 0; seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };

// The page shows link cards and media, not t.co URLs.
const clean = (s) => (s || '').replace(/https:\/\/t\.co\/\w+/g, '').replace(/\s+\n/g, '\n').trim();

function shape(raw) {
  const rt = raw.retweetedTweet;
  const t = rt || raw;
  const media = (t.media || []).map((m) => m.type).filter(Boolean);
  const out = {
    id: t.id,
    author: `@${t.author.handle}`,
    text: clean(t.text),
    quoted: t.quotedTweet ? `@${t.quotedTweet.author?.handle}: ${clean(t.quotedTweet.text)}` : '',
    media,
    context: rt ? `reposted by @${raw.author.handle}` : t.replyToUserId ? 'reply' : '',
  };
  return out;
}

const seen = new Set();
const all = [];
for (const line of readFileSync(SRC, 'utf8').split('\n')) {
  if (!line) continue;
  const raw = JSON.parse(line);
  if (OWN.has(raw.author.handle) || raw.lang !== 'en') continue;
  const t = shape(raw);
  if (seen.has(t.id) || (!t.text && !t.quoted)) continue;
  seen.add(t.id);
  all.push(t);
}
for (let i = all.length - 1; i > 0; i--) { const j = Math.floor(rand() * (i + 1)); [all[i], all[j]] = [all[j], all[i]]; }
const pool = all.slice(0, SIZE);
writeFileSync('eval/data/pool.ndjson', pool.map((t) => JSON.stringify(t)).join('\n') + '\n');
console.log(`${all.length} eligible tweets, wrote ${pool.length} to eval/data/pool.ndjson`);
