import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  normaliseSettings, requestFor, normaliseAnswers, mutesOf, isConfigured, seesImages, settingsFingerprint,
  PROVIDERS, MODEL, MAX_IMAGES,
} from '../src/wire.js';
import { ask, imagesAsData } from '../src/ask.js';

const tweet = { id: '9', author: '@a', text: 'when the build passes first try', media: ['photo'] };
const IMG = 'data:image/jpeg;base64,AAAA';

test('the old single key becomes the TypeSafe key', () => {
  const s = normaliseSettings({ apiKey: ' apikey_old ' });
  assert.equal(s.keys.typesafe, 'apikey_old');
  assert.equal('apiKey' in s, false);
  assert.equal(s.provider, 'typesafe');
  assert.equal(normaliseSettings({ provider: 'nope' }).provider, 'typesafe');
});

test('configured means a key where the route needs one', () => {
  assert.ok(!isConfigured(normaliseSettings()));
  assert.ok(isConfigured(normaliseSettings({ keys: { typesafe: 'k' } })));
  assert.ok(!isConfigured(normaliseSettings({ provider: 'openai', keys: { typesafe: 'k' } })));
  assert.ok(isConfigured(normaliseSettings({ provider: 'local' })), 'local needs no key');
});

test('TypeSafe request: pinned model, its URL and key, no images', () => {
  const s = normaliseSettings({ keys: { typesafe: 'k1' }, picked: ['rage'] });
  const req = requestFor([tweet], s, [IMG]);
  assert.equal(req.url, PROVIDERS.typesafe.url);
  assert.equal(req.body.model, MODEL);
  assert.equal(req.headers.Authorization, 'Bearer k1');
  assert.equal(JSON.stringify(req.body).includes('base64'), false);
});

test('OpenAI request carries choices and up to MAX_IMAGES images when allowed', () => {
  const s = normaliseSettings({ provider: 'openai', keys: { openai: 'sk' }, picked: ['memes'] });
  const req = requestFor([tweet], s, [IMG, IMG, IMG]);
  assert.equal(req.format, 'openai');
  const q = req.body.questions[0];
  assert.equal(q.name, 't0');
  assert.deepEqual(q.choices.map((c) => c.value), ['keep', 'c_memes']);
  const parts = req.body.input[0].content;
  assert.equal(parts.filter((p) => p.type === 'input_image').length, MAX_IMAGES);
  const off = requestFor([tweet], normaliseSettings({ ...s, sendImages: false, picked: ['rage'] }), [IMG]);
  assert.equal(typeof off.body.input, 'string', 'images off: text only');
});

test('Memes only counts on a route that sees images', () => {
  const ts = normaliseSettings({ picked: ['memes', 'rage'] });
  assert.ok(!seesImages(ts));
  assert.deepEqual(mutesOf(ts).map((m) => m.key), ['c_rage']);
  const oa = normaliseSettings({ provider: 'openai', picked: ['memes', 'rage'] });
  assert.deepEqual(mutesOf(oa).map((m) => m.key), ['c_memes', 'c_rage']);
  assert.notEqual(settingsFingerprint(ts), settingsFingerprint(oa));
});

test('local request goes to the configured URL with the optional model', () => {
  const s = normaliseSettings({ provider: 'local', localUrl: 'http://box:9000/v1/systemone', localModel: 'kev', picked: ['rage'] });
  const req = requestFor([tweet], s);
  assert.equal(req.url, 'http://box:9000/v1/systemone');
  assert.equal(req.body.model, 'kev');
  assert.equal(req.headers.Authorization, undefined);
  assert.equal(requestFor([tweet], normaliseSettings({ provider: 'local', picked: ['rage'] })).body.model, undefined);
});

test('OpenAI answers normalise to the systemone shape; refusals give no verdict', () => {
  const json = { answers: [
    { type: 'choice', name: 't0', choice: 'c_rage', probabilities: [{ value: 'keep', probability: 0.2 }, { value: 'c_rage', probability: 0.8 }] },
    { type: 'refusal', name: 't1' },
  ] };
  const n = normaliseAnswers(json, 'openai');
  assert.deepEqual(n.t0.probabilities, { keep: 0.2, c_rage: 0.8 });
  assert.equal(n.t1, undefined);
});

const reply = (status, body) => async () => ({ ok: status < 300, status, text: async () => JSON.stringify(body) });

test('ask() posts the request and returns verdicts for each route', async () => {
  const sys = normaliseSettings({ keys: { typesafe: 'k' }, picked: ['rage'] });
  let seen;
  const v = await ask(requestFor([tweet], sys), sys, { fetchImpl: async (url, init) => {
    seen = { url, body: JSON.parse(init.body) };
    return reply(200, { answers: { t0: { type: 'choice', choice: 'c_rage', probabilities: { keep: 0.1, c_rage: 0.9 } } } })();
  } });
  assert.equal(seen.url, PROVIDERS.typesafe.url);
  assert.deepEqual(v['9'], { hide: true, pKeep: 0.1, reason: 'Political rage bait' });

  const oa = normaliseSettings({ provider: 'openai', keys: { openai: 'sk' }, picked: ['rage'] });
  const v2 = await ask(requestFor([tweet], oa), oa, { fetchImpl: reply(200, { answers: [
    { type: 'choice', name: 't0', choice: 'keep', probabilities: [{ value: 'keep', probability: 0.9 }, { value: 'c_rage', probability: 0.1 }] }] }) });
  assert.equal(v2['9'].hide, false);
});

test('ask() throws with the status on an HTTP error', async () => {
  const s = normaliseSettings({ provider: 'openai', keys: { openai: 'bad' }, picked: ['rage'] });
  await assert.rejects(ask(requestFor([tweet], s), s, { fetchImpl: reply(401, { error: 'nope' }) }),
    (e) => e.status === 401 && /OpenAI Decisions 401/.test(e.message));
});

test('images become data URLs; failures are skipped', async () => {
  const fetchImpl = async (u) => (u.includes('bad') ? { ok: false } : {
    ok: true, blob: async () => new Blob([new Uint8Array([1, 2, 3])], { type: 'image/png' }),
  });
  const out = await imagesAsData(['https://pbs.twimg.com/ok', 'https://pbs.twimg.com/bad'], { fetchImpl });
  assert.deepEqual(out, ['data:image/png;base64,AQID']);
});
