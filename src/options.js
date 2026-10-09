import { normaliseSettings, requestFor, verdictsFrom, MODEL } from './wire.js';

const $ = (id) => document.getElementById(id);

function strictnessNote(v) {
  const pct = Math.round(v * 100);
  $('strictness-note').textContent = `Hide a post when Jev puts the chance you'd want it below ${pct}%.`;
}

function fromForm() {
  return normaliseSettings({
    enabled: $('enabled').checked,
    apiKey: $('key').value,
    mutes: $('mutes').value.split('\n'),
    strictness: Number($('strictness').value),
    allowHandles: $('allow').value.split(/[\s,]+/),
  });
}

async function load() {
  const { settings: raw } = await chrome.storage.local.get('settings');
  const s = normaliseSettings(raw);
  $('enabled').checked = s.enabled;
  $('key').value = s.apiKey;
  $('mutes').value = s.mutes.join('\n');
  $('strictness').value = String(s.strictness);
  $('allow').value = s.allowHandles.map((h) => `@${h}`).join(' ');
  strictnessNote(s.strictness);
}

$('strictness').addEventListener('input', (e) => strictnessNote(Number(e.target.value)));

$('save').addEventListener('click', async () => {
  const s = fromForm();
  await chrome.storage.local.set({ settings: s });
  $('saved').textContent = s.apiKey ? 'Saved. Open tabs update right away.' : 'Saved, but filtering needs a key.';
  setTimeout(() => { $('saved').textContent = ''; }, 3000);
});

// A real call with a made-up tweet, so the reader sees Jev working before they go to X.
$('test').addEventListener('click', async () => {
  const s = fromForm();
  const out = $('test-result');
  if (!s.apiKey) { out.textContent = 'Paste a key first.'; return; }
  if (!s.mutes.length) { out.textContent = 'Add at least one thing to mute first.'; return; }
  out.textContent = 'Asking Jev…';
  const sample = { id: 'sample', author: 'example', text: `A post about: ${s.mutes[0]}` };
  const req = requestFor([sample], s);
  const started = performance.now();
  try {
    const r = await fetch('https://api.typesafe.ai/v1/systemone', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${s.apiKey}` },
      body: JSON.stringify({ ...req.body, model: MODEL }),
    });
    const ms = Math.round(performance.now() - started);
    if (!r.ok) { out.textContent = `Key rejected (${r.status}). Check it and try again.`; return; }
    const v = verdictsFrom((await r.json()).answers, req.ids, s).sample;
    out.textContent = `Key works (${ms} ms). A test post about "${s.mutes[0]}" would be ${v?.hide ? 'hidden' : 'shown'}.`;
  } catch (e) {
    out.textContent = `Couldn't reach Jev: ${e.message}`;
  }
});

load();
