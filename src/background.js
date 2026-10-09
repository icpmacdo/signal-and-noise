// The only place the TypeSafe key is used. Content scripts send batches of tweets; this asks Jev,
// caches verdicts per tweet, and keeps a tally for the popup. Any failure answers "show" so the
// timeline is never held hostage by the API.
import {
  MAX_BATCH, MODEL, normaliseSettings, requestFor, verdictsFrom, isAllowed, settingsFingerprint,
} from './wire.js';

const ENDPOINT = 'https://api.typesafe.ai/v1/systemone';
const TIMEOUT_MS = 2500;
const CACHE_MAX = 3000;

const cache = new Map(); // `${fingerprint}|${tweetId}` -> verdict

async function settings() {
  const { settings: raw } = await chrome.storage.local.get('settings');
  return normaliseSettings(raw);
}

async function askJev(tweets, s) {
  const req = requestFor(tweets, s);
  if (!req) return {};
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(ENDPOINT, {
      method: 'POST',
      signal: ctl.signal,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${s.apiKey}` },
      body: JSON.stringify({ ...req.body, model: MODEL }),
    });
    const text = await r.text();
    if (!r.ok) throw new Error(`Jev ${r.status}: ${text.slice(0, 200)}`);
    return verdictsFrom(JSON.parse(text).answers, req.ids, s);
  } finally {
    clearTimeout(timer);
  }
}

async function judge(tweets) {
  const s = await settings();
  if (!s.enabled || !s.apiKey || !s.mutes.length) return { verdicts: {}, off: true };
  const fp = settingsFingerprint(s);
  const verdicts = {};
  const todo = [];
  for (const t of tweets) {
    if (isAllowed(t, s)) { verdicts[t.id] = { hide: false, allowed: true }; continue; }
    const hit = cache.get(`${fp}|${t.id}`);
    if (hit) verdicts[t.id] = hit; else todo.push(t);
  }
  const batches = [];
  for (let i = 0; i < todo.length; i += MAX_BATCH) batches.push(todo.slice(i, i + MAX_BATCH));
  let error = null;
  const results = await Promise.allSettled(batches.map((b) => askJev(b, s)));
  for (const res of results) {
    if (res.status === 'rejected') { error = String(res.reason?.message || res.reason); continue; }
    for (const [id, v] of Object.entries(res.value)) {
      verdicts[id] = v;
      cache.set(`${fp}|${id}`, v);
    }
  }
  while (cache.size > CACHE_MAX) cache.delete(cache.keys().next().value);
  if (error) await chrome.storage.local.set({ lastError: { message: error, at: Date.now() } });
  return { verdicts, error };
}

async function tally(hidden) {
  const today = new Date().toISOString().slice(0, 10);
  const { stats } = await chrome.storage.local.get('stats');
  const st = stats?.day === today ? stats : { day: today, judged: 0, hidden: 0, byReason: {} };
  st.judged += hidden.judged;
  for (const reason of hidden.reasons) {
    st.hidden += 1;
    st.byReason[reason] = (st.byReason[reason] || 0) + 1;
  }
  await chrome.storage.local.set({ stats: st });
}

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg?.type === 'judge') {
    judge(msg.tweets || []).then(reply, (e) => reply({ verdicts: {}, error: String(e) }));
    return true;
  }
  if (msg?.type === 'tally') {
    tally(msg).then(() => reply({ ok: true }));
    if (sender.tab?.id != null && msg.tabHidden != null) {
      chrome.action.setBadgeBackgroundColor({ color: '#5b5bd6', tabId: sender.tab.id });
      chrome.action.setBadgeText({ text: msg.tabHidden ? String(msg.tabHidden) : '', tabId: sender.tab.id });
    }
    return true;
  }
  return false;
});

chrome.runtime.onInstalled.addListener(async ({ reason }) => {
  if (reason === 'install') {
    const { settings: raw } = await chrome.storage.local.get('settings');
    if (!raw) await chrome.storage.local.set({ settings: normaliseSettings() });
    chrome.runtime.openOptionsPage();
  }
});
