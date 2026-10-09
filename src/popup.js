import { COMMON, PROVIDERS, normaliseSettings, isConfigured } from './wire.js';

const $ = (id) => document.getElementById(id);
const labelOf = Object.fromEntries(COMMON.map((c) => [c.id, c.label]));

async function settings() {
  const { settings: raw } = await chrome.storage.local.get('settings');
  return normaliseSettings(raw);
}
async function patch(p) {
  const s = await settings();
  await chrome.storage.local.set({ settings: normaliseSettings({ ...s, ...p }) });
}

async function render() {
  const { stats, lastError } = await chrome.storage.local.get(['stats', 'lastError']);
  const s = await settings();
  const sw = $('enabled');
  sw.setAttribute('aria-checked', String(s.enabled));
  sw.classList.toggle('on', s.enabled);

  const n = s.picked.length + s.customs.length;
  $('status').textContent = !isConfigured(s) ? `Add your ${PROVIDERS[s.provider].label} key in settings to start.` : !n ? 'Nothing muted yet.' : s.enabled ? '' : 'Paused. Everything shows.';
  $('status').hidden = !$('status').textContent;

  const today = new Date().toISOString().slice(0, 10);
  const st = stats?.day === today ? stats : { judged: 0, hidden: 0, shown: 0, good: 0, wrong: 0, byReason: {} };
  $('hidden').textContent = s.enabled ? String(st.hidden) : '0';
  $('judged').textContent = st.judged.toLocaleString();

  const items = [
    ...s.picked.map((id) => ({ label: labelOf[id], custom: false, remove: () => patch({ picked: s.picked.filter((x) => x !== id) }) })),
    ...s.customs.map((c) => ({ label: c, custom: true, remove: () => patch({ customs: s.customs.filter((x) => x !== c) }) })),
  ];
  $('mutes').replaceChildren(...items.map((m) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = `bubble on ${m.custom ? 'custom' : ''} ${s.enabled ? '' : 'paused'}`;
    b.setAttribute('aria-label', `Stop muting ${m.label}`);
    b.append(document.createTextNode(m.label));
    const c = document.createElement('span'); c.className = 'count'; c.textContent = String(st.byReason[m.label] || 0);
    b.append(c);
    b.insertAdjacentHTML('beforeend', '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"></path></svg>');
    b.addEventListener('click', m.remove);
    return b;
  }));

  const fb = [];
  if (st.shown) fb.push(`You tapped Show on ${st.shown} hidden post${st.shown === 1 ? '' : 's'} today.`);
  if (st.wrong) fb.push(`${st.wrong} marked as shouldn't have been hidden.`);
  $('feedback').textContent = fb.join(' ');
  $('feedback').hidden = !fb.length;

  const recent = lastError && Date.now() - lastError.at < 10 * 60 * 1000;
  $('error').hidden = !recent;
  if (recent) $('error').textContent = `Model error, showing everything meanwhile: ${lastError.message}`;
}

$('enabled').addEventListener('click', async () => { const s = await settings(); await patch({ enabled: !s.enabled }); });
$('add').addEventListener('submit', async (e) => {
  e.preventDefault();
  const t = $('add-input').value.trim();
  if (!t) return;
  $('add-input').value = '';
  const s = await settings();
  await patch({ customs: [...s.customs, t] });
});
$('settings').addEventListener('click', () => chrome.runtime.openOptionsPage());
chrome.storage.onChanged.addListener((changes, area) => { if (area === 'local' && (changes.settings || changes.stats)) render(); });

render();
