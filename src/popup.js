import { normaliseSettings } from './wire.js';

const $ = (id) => document.getElementById(id);

async function render() {
  const { settings: raw, stats, lastError } = await chrome.storage.local.get(['settings', 'stats', 'lastError']);
  const s = normaliseSettings(raw);
  $('enabled').checked = s.enabled;
  $('status').textContent = !s.apiKey ? 'Add your TypeSafe key in settings to start.'
    : !s.mutes.length ? 'Nothing muted yet.'
      : s.enabled ? `Muting ${s.mutes.length} kind${s.mutes.length === 1 ? '' : 's'} of post.` : 'Paused.';

  const today = new Date().toISOString().slice(0, 10);
  const st = stats?.day === today ? stats : { judged: 0, hidden: 0, byReason: {} };
  $('hidden').textContent = String(st.hidden);
  $('judged').textContent = String(st.judged);
  const ul = $('reasons');
  ul.replaceChildren(...Object.entries(st.byReason).sort((a, b) => b[1] - a[1]).map(([reason, n]) => {
    const li = document.createElement('li');
    li.textContent = `${n} · ${reason}`;
    return li;
  }));

  const recent = lastError && Date.now() - lastError.at < 10 * 60 * 1000;
  $('error').hidden = !recent;
  if (recent) $('error').textContent = `Jev error, showing everything meanwhile: ${lastError.message}`;
}

$('enabled').addEventListener('change', async (e) => {
  const { settings: raw } = await chrome.storage.local.get('settings');
  await chrome.storage.local.set({ settings: normaliseSettings({ ...raw, enabled: e.target.checked }) });
  render();
});
$('settings').addEventListener('click', () => chrome.runtime.openOptionsPage());

render();
