import { COMMON, normaliseSettings, requestFor, verdictsFrom, MODEL } from './wire.js';

const $ = (id) => document.getElementById(id);
const IDEAS = ['Anything about the Oilers', 'Posts by reply guys', 'Election predictions', 'Apple rumours'];

// Sample posts for the preview. `tag` is the bubble each one is written to match, used only when
// there's no key to ask Jev with; `words` lets a typed mute match it in that fallback.
const SAMPLES = [
  { id: 'p1', author: '@kernel_ken', text: 'spent the day chasing a 2% regression. it was a changed default in the allocator. read the changelogs, folks' },
  { id: 'p2', author: '@moonboi', text: '$PEPE2 is going 100x by Friday. Not financial advice. Get in before it is too late', tag: 'crypto' },
  { id: 'p3', author: '@ux_uma', text: '6 user interviews on the onboarding flow. 5 of 6 skipped the tutorial at the same step. cutting it.' },
  { id: 'p4', author: '@growthguru', text: "Like if you agree, ignore if you're a hater. Who's still up? Reply with your city!", tag: 'engage' },
  { id: 'p5', author: '@tv_tanya', text: 'that Severance finale reveal about Helly in the last ten minutes... I screamed', tag: 'spoil', words: ['severance', 'spoiler'] },
  { id: 'p6', author: '@angrypundit', text: "The other party wants to DESTROY this country. If you can't see it you're part of the problem", tag: 'rage' },
  { id: 'p7', author: '@hype_fan_22', text: "We are not ready for what's coming in the next 6 months. Nothing will ever be the same.", tag: 'hype' },
  { id: 'p8', author: '@oilers_owen', text: 'McDavid with four points tonight. Oilers win 5-2 and move into first.', tag: 'sports', words: ['oilers', 'hockey', 'nhl'] },
  { id: 'p9', author: '@baker_jo', text: 'third attempt at sourdough and it finally has an open crumb' },
];

const looksLikeKey = (t) => /^apikey_[\w-]{16,}$/.test(t) || (!/\s/.test(t) && t.length >= 40 && /\d/.test(t));

let S = normaliseSettings();
let previewTimer = null;
let previewSeq = 0;
const jevCache = new Map(); // fingerprint|sampleId -> verdict

async function load() {
  const { settings: raw } = await chrome.storage.local.get('settings');
  S = normaliseSettings(raw);
  const stray = S.customs.find(looksLikeKey);
  if (stray) {
    S = normaliseSettings({ ...S, apiKey: S.apiKey || stray, customs: S.customs.filter((c) => !looksLikeKey(c)) });
    await chrome.storage.local.set({ settings: S });
  }
  $('enabled').checked = S.enabled;
  $('key').value = S.apiKey;
  $('allow').value = S.allowHandles.map((h) => `@${h}`).join(' ');
  if (!S.apiKey) $('key-box').open = true;
  render();
}

let saveTimer = null;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    await chrome.storage.local.set({ settings: S });
    $('saved').textContent = S.apiKey ? 'Saved. Open X tabs update right away.' : 'Saved. Add your TypeSafe key below to start filtering.';
  }, 250);
}

function change(patch) {
  S = normaliseSettings({ ...S, ...patch });
  render();
  save();
}

function bubble(label, { pressed, hint, cls = '', onClick, remove }) {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = `bubble ${cls}`;
  if (pressed != null) b.setAttribute('aria-pressed', String(pressed));
  if (hint) b.title = hint;
  if (pressed) b.insertAdjacentHTML('beforeend', '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"></path></svg>');
  b.append(document.createTextNode(label));
  if (remove) {
    b.setAttribute('aria-label', `Remove ${label}`);
    b.insertAdjacentHTML('beforeend', '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"></path></svg>');
  }
  b.addEventListener('click', onClick);
  return b;
}

function render() {
  $('common').replaceChildren(...COMMON.map((c) => {
    const on = S.picked.includes(c.id);
    return bubble(c.label, { pressed: on, hint: c.hint, cls: on ? 'on' : '',
      onClick: () => change({ picked: on ? S.picked.filter((x) => x !== c.id) : [...S.picked, c.id] }) });
  }));
  $('customs').replaceChildren(...S.customs.map((c) => bubble(c, { cls: 'custom', remove: true,
    onClick: () => change({ customs: S.customs.filter((x) => x !== c) }) })));
  const ideas = IDEAS.filter((i) => !S.customs.some((c) => c.toLowerCase() === i.toLowerCase()));
  $('ideas').replaceChildren($('ideas').firstElementChild, ...ideas.map((i) => bubble(`+ ${i}`, { cls: 'idea', onClick: () => change({ customs: [...S.customs, i] }) })));
  const n = S.picked.length + S.customs.length;
  $('count').textContent = `${n} muted`;
  schedulePreview();
}

// ---- preview ---------------------------------------------------------------------------------

function fallbackVerdict(p) {
  const common = COMMON.find((c) => c.id === p.tag);
  if (common && S.picked.includes(p.tag)) return { hide: true, reason: common.label };
  for (const c of S.customs) {
    const lc = c.toLowerCase();
    if ((p.words || []).some((w) => lc.includes(w))) return { hide: true, reason: c };
  }
  return { hide: false };
}

async function jevVerdict(p, fp) {
  const k = `${fp}|${p.id}`;
  if (jevCache.has(k)) return jevCache.get(k);
  const req = requestFor([p], S);
  if (!req) return { hide: false };
  const r = await fetch('https://api.typesafe.ai/v1/systemone', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${S.apiKey}` },
    body: JSON.stringify({ ...req.body, model: MODEL }),
  });
  if (!r.ok) throw new Error(`Jev ${r.status}`);
  const v = verdictsFrom((await r.json()).answers, req.ids, S)[p.id] || { hide: false };
  jevCache.set(k, v);
  return v;
}

function renderPreview(verdicts, live) {
  let hidden = 0;
  $('preview').replaceChildren(...SAMPLES.map((p) => {
    const v = verdicts[p.id] || { hide: false };
    const row = document.createElement('div');
    if (S.enabled && v.hide) {
      hidden++;
      row.className = 'pv-bar';
      const why = document.createElement('span'); why.textContent = `Hidden · ${v.reason || 'muted'}`;
      const show = document.createElement('span'); show.className = 'pv-show'; show.textContent = 'Show';
      row.append(why, show);
    } else {
      row.className = 'pv-post';
      const who = document.createElement('div'); who.className = 'pv-who'; who.textContent = p.author;
      const txt = document.createElement('div'); txt.textContent = p.text;
      row.append(who, txt);
    }
    return row;
  }));
  $('preview-sum').textContent = S.enabled ? `${hidden} of ${SAMPLES.length} hidden` : 'Filtering is off';
  $('preview-note').textContent = live ? 'Sample posts, judged by Jev just now with your mutes.'
    : 'Sample posts. Add your key to see Jev judge them; in your feed, Jev decides.';
}

function schedulePreview() {
  const fallback = Object.fromEntries(SAMPLES.map((p) => [p.id, fallbackVerdict(p)]));
  if (!S.apiKey || !(S.picked.length + S.customs.length)) { renderPreview(fallback, false); return; }
  clearTimeout(previewTimer);
  previewTimer = setTimeout(async () => {
    const seq = ++previewSeq;
    const fp = JSON.stringify([S.picked, S.customs]);
    try {
      const vs = await Promise.all(SAMPLES.map((p) => jevVerdict(p, fp)));
      if (seq === previewSeq) renderPreview(Object.fromEntries(SAMPLES.map((p, i) => [p.id, vs[i]])), true);
    } catch {
      if (seq === previewSeq) renderPreview(fallback, false);
    }
  }, 500);
}

// ---- inputs ----------------------------------------------------------------------------------

$('custom-form').addEventListener('submit', (e) => {
  e.preventDefault();
  const t = $('custom').value.trim();
  if (!t) return;
  $('custom').value = '';
  // A pasted API key is never a mute: move it to the key field instead of sending it to Jev as one.
  if (looksLikeKey(t)) {
    $('key').value = t; $('key-box').open = true; jevCache.clear();
    change({ apiKey: t });
    $('test-result').textContent = 'That looked like your TypeSafe key, so it went in the key field.';
    return;
  }
  change({ customs: [...S.customs, t] });
});
$('enabled').addEventListener('change', (e) => change({ enabled: e.target.checked }));
$('allow').addEventListener('change', (e) => change({ allowHandles: e.target.value.split(/[\s,]+/) }));
$('key').addEventListener('change', (e) => { jevCache.clear(); change({ apiKey: e.target.value }); });

$('test').addEventListener('click', async () => {
  const s = normaliseSettings({ ...S, apiKey: $('key').value });
  const out = $('test-result');
  if (!s.apiKey) { out.textContent = 'Paste a key first.'; return; }
  out.textContent = 'Asking Jev…';
  const started = performance.now();
  try {
    const r = await fetch('https://api.typesafe.ai/v1/systemone', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${s.apiKey}` },
      body: JSON.stringify({ model: MODEL, state: { tweet: 'hello' }, questions: { q: { type: 'noul', instructions: 'Is this a greeting?' } } }),
    });
    const ms = Math.round(performance.now() - started);
    out.textContent = r.ok ? `Key works (${ms} ms).` : `Key rejected (${r.status}). Check it and try again.`;
    if (r.ok) { jevCache.clear(); change({ apiKey: s.apiKey }); }
  } catch (e) {
    out.textContent = `Couldn't reach Jev: ${e.message}`;
  }
});

load();
