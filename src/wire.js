// What we ask a decision model about a tweet, and how its answer becomes a hide/show verdict.
// Pure: no network, no chrome.*, so it runs under `node --test` and the extension asks the same
// questions. Three routes: TypeSafe's Jev, OpenAI's Decisions API, and any server that speaks
// TypeSafe's /v1/systemone protocol (Kev via llama.cpp or its own server, self-hosted Jev-likes).
//
// One request per tweet: in a shared request Jev compares tweets with each other, and 11 of 40
// borderline tweets flipped verdict depending only on their neighbours (eval/synthetic). The tweet
// gets one `choice` question whose labels are "keep" plus one per mute, the common picks and
// whatever the reader typed. Jev judges every mute one-shot; there is nothing per mute to tune.

export const MAX_BATCH = 1;
// Pinned so a model update can't silently move what gets hidden; re-run the eval before bumping.
export const MODEL = 'jev-1.13.0';

export const PROVIDERS = {
  typesafe: { label: 'TypeSafe Jev', url: 'https://api.typesafe.ai/v1/systemone', model: MODEL, format: 'systemone', key: true, images: false },
  openai: { label: 'OpenAI Decisions', url: 'https://api.openai.com/v1/decisions', model: 'gpt-6-luna', format: 'openai', key: true, images: true },
  local: { label: 'Local or self-hosted', url: 'http://localhost:8080/v1/systemone', model: '', format: 'systemone', key: false, images: false },
};
export const MAX_IMAGES = 2;
// Hide when Jev thinks a mute is more likely than "keep".
export const HIDE_BELOW = 0.5;

// The bubbles on the settings page. The hint goes to Jev with the label, so it is written for both.
export const COMMON = [
  { id: 'rage', label: 'Political rage bait', hint: 'outrage-farming about politics' },
  { id: 'crypto', label: 'Crypto & memecoin shilling', hint: 'coin pumps, "100x" calls, wallet-connect links' },
  { id: 'engage', label: 'Engagement bait', hint: "'like if you agree', reply or repost farming, fake giveaways" },
  { id: 'hype', label: 'Vague AI hype', hint: "'this changes everything', 'X is dead', claims with no substance" },
  { id: 'dunk', label: 'Dunking & pile-ons', hint: 'mocking or quote-dunking someone else; not self-deprecation or fair criticism' },
  { id: 'doom', label: 'Doom posting', hint: "'we're all cooked', collapse is coming" },
  { id: 'hustle', label: 'Hustle & get-rich-quick', hint: 'passive income and side-hustle gurus' },
  { id: 'flex', label: 'Revenue flexing', hint: "'I made $40k MRR in 30 days' posts" },
  { id: 'thread', label: 'Thread bait', hint: "listicle hook threads ('10 AI tools that will save you 10 hours 🧵', 'here is what nobody tells you'); not ordinary threads, rants or opinions" },
  { id: 'culture', label: 'Culture-war bait', hint: 'gender wars and identity fights posted for clicks' },
  { id: 'sports', label: 'Sports', hint: 'scores, trades, hot takes' },
  { id: 'celeb', label: 'Celebrity gossip', hint: 'who is dating whom' },
  { id: 'spoil', label: 'TV & movie spoilers', hint: 'plot details for shows and films' },
  { id: 'violence', label: 'Graphic violence', hint: 'fights, accidents, war footage' },
  { id: 'thirst', label: 'Thirst traps', hint: 'suggestive selfies posted for engagement' },
  { id: 'slop', label: 'AI slop images', hint: 'low-effort generated pictures' },
  { id: 'ads', label: 'Promoted posts', hint: 'ads in the timeline' },
  { id: 'video', label: 'Videos', hint: 'any post with a video or GIF in it' },
  { id: 'politics', label: 'Politics, all of it', hint: 'any post about elections, parties, politicians or government, calm or not' },
  { id: 'promo', label: 'Self-promotion', hint: 'people plugging their own product, course, newsletter or launch' },
  // Needs a model that sees the picture: the joke is in the image, so text alone is a coin flip.
  { id: 'memes', label: 'Memes', hint: 'meme images, reaction pictures and joke formats', needsImages: true },
];
const COMMON_BY_ID = Object.fromEntries(COMMON.map((c) => [c.id, c]));

export const DEFAULT_SETTINGS = {
  enabled: true,
  provider: 'typesafe',
  keys: { typesafe: '', openai: '', local: '' },
  localUrl: PROVIDERS.local.url,
  localModel: '',
  sendImages: true,
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
  // Before providers there was one key, for TypeSafe.
  const keys = { ...DEFAULT_SETTINGS.keys, ...(r.keys || {}) };
  if (r.apiKey && !keys.typesafe) keys.typesafe = r.apiKey;
  for (const k of Object.keys(keys)) keys[k] = String(keys[k] || '').trim();
  s.keys = keys;
  delete s.apiKey;
  s.provider = PROVIDERS[s.provider] ? s.provider : 'typesafe';
  s.localUrl = String(s.localUrl || '').trim() || PROVIDERS.local.url;
  s.localModel = String(s.localModel || '').trim();
  s.sendImages = s.sendImages !== false;
  s.enabled = s.enabled !== false;
  return s;
}

/** Whether the chosen route can see images and the reader allowed sending them. */
export function seesImages(s) {
  return PROVIDERS[s.provider].images && s.sendImages;
}

/** Ready to ask: a key where the route needs one, and a URL for the local route. */
export function isConfigured(s) {
  const p = PROVIDERS[s.provider];
  return p.key ? !!s.keys[s.provider] : !!s.localUrl;
}

/** Every active mute: key (sent to Jev), label (shown to the reader), text (what Jev reads). */
export function mutesOf(s) {
  return [
    // Common bubbles are kinds of post, so they say "a post that is itself …": with the "about, or
    // an example of" question, a bare label let posts that only talk about it match (a joke about
    // writing threads was hidden as thread bait).
    ...s.picked.filter((id) => !COMMON_BY_ID[id].needsImages || seesImages(s)).map((id) => ({ key: `c_${id}`, label: COMMON_BY_ID[id].label,
      text: `A post that is itself ${COMMON_BY_ID[id].label.toLowerCase()} (${COMMON_BY_ID[id].hint}); posts that only talk about it don't count` })),
    ...s.customs.map((c, i) => ({ key: `u${i}`, label: c, text: c })),
  ];
}

/** Cache key part that changes whenever a verdict could change. */
export function settingsFingerprint(s) {
  return JSON.stringify([s.picked, s.customs, s.provider, s.provider === 'local' ? [s.localUrl, s.localModel] : '', seesImages(s)]);
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

const INSTRUCTIONS = 'A reader has muted the things listed below on X. Is this tweet about, or an example '
  + 'of, any of them? Pick that one. Answer "keep" if it isn\'t, including when it only mentions '
  + 'one in passing.';
// Mutes are a mix of kinds of post ("engagement bait") and topics ("anything about the Oilers").
// "About, or an example of" covers both; the older "clearly a kind of post" wording left topic
// mutes mostly unhidden (sourdough vs "home baking": P(keep) 0.75 -> 0.13).

/**
 * One request for one tweet (extra tweets are ignored: see MAX_BATCH), shaped for the chosen
 * route. The question is named t0 so an arbitrary tweet id never ends up as a key the API might
 * reject; `ids` maps it back. `images` are data: URLs, sent only on routes that see images.
 */
export function requestFor(tweets, settings, images = []) {
  const mutes = mutesOf(settings);
  if (!mutes.length || !tweets.length) return null;
  const t = tweets[0];
  const p = PROVIDERS[settings.provider];
  const key = settings.keys[settings.provider];
  const headers = { 'Content-Type': 'application/json' };
  if (key) headers.Authorization = `Bearer ${key}`;
  const criteria = criteriaFor(mutes);
  const ids = { t0: t.id };
  if (p.format === 'openai') {
    const text = JSON.stringify({ tweet: tweetState(t) });
    const imgs = seesImages(settings) ? images.slice(0, MAX_IMAGES) : [];
    return {
      url: p.url, headers, ids, format: 'openai',
      body: {
        model: p.model,
        input: imgs.length
          ? [{ role: 'user', content: [{ type: 'input_text', text }, ...imgs.map((u) => ({ type: 'input_image', image_url: u }))] }]
          : text,
        questions: [{ type: 'choice', name: 't0', instructions: INSTRUCTIONS,
          choices: Object.entries(criteria).map(([value, description]) => ({ value, description })) }],
      },
    };
  }
  const url = settings.provider === 'local' ? settings.localUrl : p.url;
  const model = settings.provider === 'local' ? settings.localModel : p.model;
  const body = { state: { tweet: tweetState(t) }, questions: { t0: { type: 'choice', instructions: INSTRUCTIONS, criteria } } };
  if (model) body.model = model;
  return { url, headers, ids, format: 'systemone', body };
}

/** Bring either API's response into one shape: { t0: { type: 'choice', choice, probabilities: {value: p} } }. */
export function normaliseAnswers(json, format) {
  if (format !== 'openai') return json?.answers || {};
  const out = {};
  for (const a of json?.answers || []) {
    if (a.type !== 'choice') continue; // a refusal or anything unexpected: no verdict, the tweet shows
    const probabilities = Object.fromEntries((a.probabilities || []).map((p) => [p.value, p.probability]));
    out[a.name] = { type: 'choice', choice: a.choice, probabilities, confidence: a.confidence };
  }
  return out;
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
