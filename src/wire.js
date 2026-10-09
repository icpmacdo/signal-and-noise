// What we ask Jev about a batch of tweets, and how its answers become hide/show verdicts. Pure:
// no network, no chrome.*, so it runs under `node --test` and the extension asks the same questions.
//
// One request carries several tweets. Each tweet gets its own `choice` question whose labels are
// "keep" plus one label per thing the reader muted; Jev returns a probability for each, and we
// hide only when "keep" is unlikely enough for the reader's strictness.

export const MAX_BATCH = 10;

export const DEFAULT_SETTINGS = {
  enabled: true,
  apiKey: '',
  mutes: [
    'Rage bait or outrage-farming about politics',
    'Crypto, memecoin or get-rich-quick shilling',
    "Engagement bait: 'like if you agree', reply or repost farming, fake giveaways",
  ],
  // Hide when P(keep) falls below this. Lower = only hide clear matches.
  strictness: 0.35,
  allowHandles: [],
};

/** Normalise whatever is in storage into a usable settings object. */
export function normaliseSettings(raw = {}) {
  const s = { ...DEFAULT_SETTINGS, ...raw };
  s.mutes = (Array.isArray(s.mutes) ? s.mutes : []).map((m) => String(m).trim()).filter(Boolean);
  s.allowHandles = (Array.isArray(s.allowHandles) ? s.allowHandles : [])
    .map((h) => String(h).trim().replace(/^@/, '').toLowerCase()).filter(Boolean);
  const k = Number(s.strictness);
  s.strictness = Number.isFinite(k) ? Math.min(0.95, Math.max(0.05, k)) : DEFAULT_SETTINGS.strictness;
  s.apiKey = String(s.apiKey || '').trim();
  s.enabled = s.enabled !== false;
  return s;
}

/** Cache key part that changes whenever a verdict could change. */
export function settingsFingerprint(s) {
  return JSON.stringify([s.mutes, s.strictness]);
}

/** The criteria map shared by every question: "keep" plus m0..mN for the mutes. */
export function criteriaFor(mutes) {
  const criteria = { keep: "none of these; it's an ordinary post the reader would want to see" };
  mutes.forEach((m, i) => { criteria[`m${i}`] = m; });
  return criteria;
}

/** Strip a tweet down to what Jev needs to judge it. */
export function tweetState(t) {
  const out = { author: t.author || 'unknown', text: (t.text || '').slice(0, 1200) };
  if (t.quoted) out.quoting = t.quoted.slice(0, 600);
  if (t.media && t.media.length) out.media = t.media.slice(0, 4).map((m) => m.slice(0, 200));
  if (t.context) out.context = t.context.slice(0, 120);
  return out;
}

/**
 * One request for up to MAX_BATCH tweets. Question keys are t0..tN so arbitrary tweet ids never
 * end up as JSON keys the API might reject; `ids` maps them back.
 */
export function requestFor(tweets, settings) {
  if (!settings.mutes.length || !tweets.length) return null;
  const batch = tweets.slice(0, MAX_BATCH);
  const criteria = criteriaFor(settings.mutes);
  const state = { tweets: {} };
  const questions = {};
  const ids = {};
  batch.forEach((t, i) => {
    const key = `t${i}`;
    ids[key] = t.id;
    state.tweets[key] = tweetState(t);
    questions[key] = {
      type: 'choice',
      instructions: `Judge only tweet ${key} in the state. A reader scrolling X has listed kinds of posts `
        + `they don't want to see. Does tweet ${key} clearly fall into one of them? Answer "keep" `
        + `unless it clearly does; an ordinary post that merely mentions a topic is "keep".`,
      criteria,
    };
  });
  return { body: { state, questions }, ids };
}

/** Turn Jev's answers into { [tweetId]: verdict }. Missing answers are left out (shown). */
export function verdictsFrom(answers, ids, settings) {
  const out = {};
  for (const [key, id] of Object.entries(ids)) {
    const a = answers?.[key];
    if (!a || a.type !== 'choice') continue;
    const probs = a.probabilities || {};
    const pKeep = typeof probs.keep === 'number' ? probs.keep : (a.choice === 'keep' ? 1 : 0);
    // The most likely muted label, even if "keep" won, so the bar can say why.
    let mute = null; let best = -1;
    for (const [label, p] of Object.entries(probs)) {
      if (label !== 'keep' && p > best) { best = p; mute = label; }
    }
    if (!mute && a.choice !== 'keep') mute = a.choice;
    const idx = mute ? Number(mute.slice(1)) : -1;
    out[id] = {
      hide: pKeep < settings.strictness,
      pKeep: Math.round(pKeep * 100) / 100,
      reason: idx >= 0 ? settings.mutes[idx] ?? null : null,
    };
  }
  return out;
}

/** Tweets from allow-listed authors never go to Jev. */
export function isAllowed(tweet, settings) {
  const handle = String(tweet.author || '').replace(/^@/, '').toLowerCase();
  return settings.allowHandles.includes(handle);
}
