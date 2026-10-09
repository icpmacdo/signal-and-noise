// What we ask Jev about a tweet, and how its answer becomes a hide/show verdict. Pure: no
// network, no chrome.*, so it runs under `node --test` and the extension asks the same questions.
//
// One request per tweet: in a shared request Jev compares tweets with each other, and 11 of 40
// borderline tweets flipped verdict depending only on their neighbours (eval/synthetic). The tweet
// gets one `choice` question whose labels are "keep" plus one per mute, the common picks and
// whatever the reader typed. Jev judges every mute one-shot; there is nothing per mute to tune.

export const MAX_BATCH = 1;
// Pinned so a model update can't silently move what gets hidden; re-run the eval before bumping.
export const MODEL = 'jev-1.13.0';
// Hide when Jev thinks a mute is more likely than "keep".
export const HIDE_BELOW = 0.5;

// The bubbles on the settings page. The hint goes to Jev with the label, so it is written for both.
export const COMMON = [
  { id: 'rage', label: 'Political rage bait', hint: 'outrage-farming about politics' },
  { id: 'crypto', label: 'Crypto & memecoin shilling', hint: 'coin pumps, "100x" calls, wallet-connect links' },
  { id: 'engage', label: 'Engagement bait', hint: "'like if you agree', reply or repost farming, fake giveaways" },
  { id: 'hype', label: 'Vague AI hype', hint: "'this changes everything', 'X is dead', claims with no substance" },
  { id: 'dunk', label: 'Dunking & pile-ons', hint: 'mocking or quote-dunking someone' },
  { id: 'doom', label: 'Doom posting', hint: "'we're all cooked', collapse is coming" },
  { id: 'hustle', label: 'Hustle & get-rich-quick', hint: 'passive income and side-hustle gurus' },
  { id: 'flex', label: 'Revenue flexing', hint: "'I made $40k MRR in 30 days' posts" },
  { id: 'thread', label: 'Thread bait', hint: "'10 tools that will save you 10 hours, a thread'" },
  { id: 'culture', label: 'Culture-war bait', hint: 'gender wars and identity fights posted for clicks' },
  { id: 'sports', label: 'Sports', hint: 'scores, trades, hot takes' },
  { id: 'celeb', label: 'Celebrity gossip', hint: 'who is dating whom' },
  { id: 'spoil', label: 'TV & movie spoilers', hint: 'plot details for shows and films' },
  { id: 'violence', label: 'Graphic violence', hint: 'fights, accidents, war footage' },
  { id: 'thirst', label: 'Thirst traps', hint: 'suggestive selfies posted for engagement' },
  { id: 'slop', label: 'AI slop images', hint: 'low-effort generated pictures' },
  { id: 'ads', label: 'Promoted posts', hint: 'ads in the timeline' },
];
const COMMON_BY_ID = Object.fromEntries(COMMON.map((c) => [c.id, c]));

export const DEFAULT_SETTINGS = {
  enabled: true,
  apiKey: '',
  picked: ['rage', 'crypto', 'engage'],
  customs: [],
  allowHandles: [],
};

// Settings saved before the bubble picker held free-text `mutes`; the three old defaults map onto
// bubbles and anything else becomes a custom mute.
const OLD_DEFAULTS = {
  'Rage bait or outrage-farming about politics': 'rage',
  'Crypto, memecoin or get-rich-quick shilling': 'crypto',
  "Engagement bait: 'like if you agree', reply or repost farming, fake giveaways": 'engage',
};

/** Normalise whatever is in storage into a usable settings object. */
export function normaliseSettings(raw = {}) {
  const r = { ...raw };
  if (Array.isArray(r.mutes) && !Array.isArray(r.picked) && !Array.isArray(r.customs)) {
    r.picked = []; r.customs = [];
    for (const m of r.mutes) (OLD_DEFAULTS[m] ? r.picked : r.customs).push(OLD_DEFAULTS[m] || m);
  }
  const s = { ...DEFAULT_SETTINGS, ...r };
  delete s.mutes; delete s.strictness;
  s.picked = [...new Set((Array.isArray(s.picked) ? s.picked : []).filter((id) => COMMON_BY_ID[id]))];
  const seen = new Set();
  s.customs = (Array.isArray(s.customs) ? s.customs : []).map((m) => String(m).trim().slice(0, 200))
    .filter((m) => m && !seen.has(m.toLowerCase()) && seen.add(m.toLowerCase()));
  s.allowHandles = (Array.isArray(s.allowHandles) ? s.allowHandles : [])
    .map((h) => String(h).trim().replace(/^@/, '').toLowerCase()).filter(Boolean);
  s.apiKey = String(s.apiKey || '').trim();
  s.enabled = s.enabled !== false;
  return s;
}

/** Every active mute: key (sent to Jev), label (shown to the reader), text (what Jev reads). */
export function mutesOf(s) {
  return [
    ...s.picked.map((id) => ({ key: `c_${id}`, label: COMMON_BY_ID[id].label, text: `${COMMON_BY_ID[id].label}: ${COMMON_BY_ID[id].hint}` })),
    ...s.customs.map((c, i) => ({ key: `u${i}`, label: c, text: c })),
  ];
}

/** Cache key part that changes whenever a verdict could change. */
export function settingsFingerprint(s) {
  return JSON.stringify([s.picked, s.customs]);
}

/** The criteria map: "keep" plus one entry per active mute. */
export function criteriaFor(mutes) {
  const criteria = { keep: "none of these; it's an ordinary post the reader would want to see" };
  for (const m of mutes) criteria[m.key] = m.text;
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
 * One request for one tweet (extra tweets are ignored: see MAX_BATCH). The question key is t0 so
 * an arbitrary tweet id never ends up as a JSON key the API might reject; `ids` maps it back.
 */
export function requestFor(tweets, settings) {
  const mutes = mutesOf(settings);
  if (!mutes.length || !tweets.length) return null;
  const t = tweets[0];
  return {
    body: {
      state: { tweet: tweetState(t) },
      questions: {
        t0: {
          type: 'choice',
          // Mutes are a mix of kinds of post ("engagement bait") and topics ("anything about the
          // Oilers"). "About, or an example of" covers both; the older "clearly a kind of post"
          // wording left topic mutes mostly unhidden (sourdough vs "home baking": P(keep) 0.75 → 0.13).
          instructions: 'A reader has muted the things listed below on X. Is this tweet about, or an example '
            + 'of, any of them? Pick that one. Answer "keep" if it isn\'t, including when it only mentions '
            + 'one in passing.',
          criteria: criteriaFor(mutes),
        },
      },
    },
    ids: { t0: t.id },
  };
}

/** Turn Jev's answers into { [tweetId]: verdict }. Missing answers are left out (shown). */
export function verdictsFrom(answers, ids, settings) {
  const byKey = Object.fromEntries(mutesOf(settings).map((m) => [m.key, m]));
  const out = {};
  for (const [key, id] of Object.entries(ids)) {
    const a = answers?.[key];
    if (!a || a.type !== 'choice') continue;
    const probs = a.probabilities || {};
    const pKeep = typeof probs.keep === 'number' ? probs.keep : (a.choice === 'keep' ? 1 : 0);
    // The most likely mute, even if "keep" won, so the bar can say why.
    let mute = null; let best = -1;
    for (const [label, p] of Object.entries(probs)) {
      if (label !== 'keep' && p > best) { best = p; mute = label; }
    }
    if (!mute && a.choice !== 'keep') mute = a.choice;
    out[id] = {
      hide: pKeep < HIDE_BELOW,
      pKeep: Math.round(pKeep * 100) / 100,
      reason: byKey[mute]?.label ?? null,
    };
  }
  return out;
}

/** Tweets from allow-listed authors never go to Jev. */
export function isAllowed(tweet, settings) {
  const handle = String(tweet.author || '').replace(/^@/, '').toLowerCase();
  return settings.allowHandles.includes(handle);
}
