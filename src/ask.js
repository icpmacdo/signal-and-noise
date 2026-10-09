// The one network call: send a requestFor() request to whichever route is chosen and turn the
// answer into verdicts. Shared by the background worker (the feed) and the options page (preview,
// Test). `fetchImpl` is injectable so tests can stand in for the API.
import { PROVIDERS, normaliseAnswers, verdictsFrom } from './wire.js';

// TypeSafe answers in ~150 ms; OpenAI and self-hosted servers are slower. The content script shows
// tweets after its own fail-open delay anyway, so a late verdict only folds a tweet afterwards.
export const TIMEOUT_MS = { typesafe: 2500, openai: 6000, local: 6000 };

export async function ask(req, settings, { fetchImpl = fetch, signal } = {}) {
  const r = await fetchImpl(req.url, {
    method: 'POST',
    signal,
    headers: req.headers,
    body: JSON.stringify(req.body),
  });
  const text = await r.text();
  if (!r.ok) {
    const err = new Error(`${PROVIDERS[settings.provider].label} ${r.status}: ${text.slice(0, 200)}`);
    err.status = r.status;
    throw err;
  }
  return verdictsFrom(normaliseAnswers(JSON.parse(text), req.format), req.ids, settings);
}

/** Fetch tweet images (pbs.twimg.com URLs) as data: URLs; any that fail are skipped. */
export async function imagesAsData(urls, { fetchImpl = fetch, signal } = {}) {
  const out = await Promise.all(urls.map(async (u) => {
    try {
      const r = await fetchImpl(u, { signal });
      if (!r.ok) return null;
      const blob = await r.blob();
      const bytes = new Uint8Array(await blob.arrayBuffer());
      let bin = '';
      for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      return `data:${blob.type || 'image/jpeg'};base64,${btoa(bin)}`;
    } catch { return null; }
  }));
  return out.filter(Boolean);
}
