// The candidate ways of asking Jev, side by side. Each returns { state, questions } plus a reader
// that turns answers into a per-mute score in [0,1] where higher = more like noise.

const KEEP = "none of these; it's an ordinary post the reader would want to see";

export function payload(t) {
  const out = { author: t.author, text: t.text.slice(0, 1200) };
  if (t.quoted) out.quoting = t.quoted.slice(0, 600);
  if (t.media?.length) out.media = t.media.slice(0, 4);
  if (t.context) out.context = t.context;
  return out;
}

// A: one choice question, "keep" vs each mute. Score per mute = its probability; overall = 1 - P(keep).
export const choice = {
  name: 'choice',
  request(tweets, mutes) {
    const criteria = Object.fromEntries([['keep', KEEP], ...mutes.map((m, i) => [`m${i}`, m])]);
    const state = tweets.length === 1 ? { tweet: payload(tweets[0]) } : { tweets: Object.fromEntries(tweets.map((t, i) => [`t${i}`, payload(t)])) };
    const questions = {};
    tweets.forEach((t, i) => {
      const who = tweets.length === 1 ? 'this tweet' : `tweet t${i}`;
      questions[`t${i}`] = { type: 'choice', criteria,
        instructions: `${tweets.length === 1 ? '' : `Judge only tweet t${i} in the state. `}A reader scrolling X has listed kinds of posts `
          + `they don't want to see. Does ${who} clearly fall into one of them? Answer "keep" `
          + `unless it clearly does; an ordinary post that merely mentions a topic is "keep".` };
    });
    return { state, questions };
  },
  read(answers, i, mutes) {
    const p = answers[`t${i}`]?.probabilities;
    if (!p) return null;
    return { any: 1 - (p.keep ?? 0), per: mutes.map((_, j) => p[`m${j}`] ?? 0) };
  },
};

// B: one yes/no (noul) question per mute, single tweet. Overall = max over mutes.
export const noul = {
  name: 'noul',
  request(tweets, mutes) {
    if (tweets.length !== 1) throw new Error('noul design is one tweet per call');
    const questions = Object.fromEntries(mutes.map((m, j) => [`m${j}`, { type: 'noul',
      instructions: `A reader scrolling X does not want to see posts of this kind: "${m}". `
        + 'Is this tweet clearly that kind of post? An ordinary post that merely mentions the topic is not.' }]));
    return { state: { tweet: payload(tweets[0]) }, questions };
  },
  read(answers, _i, mutes) {
    const per = mutes.map((_, j) => answers[`m${j}`]?.noul);
    if (per.some((v) => typeof v !== 'number')) return null;
    return { any: Math.max(...per), per };
  },
};
