import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  normaliseSettings, requestFor, verdictsFrom, isAllowed, MAX_BATCH, settingsFingerprint,
} from '../src/wire.js';

const s = normaliseSettings({ mutes: ['politics rage bait', 'crypto shilling'], strictness: 0.35 });

test('settings are cleaned up', () => {
  const n = normaliseSettings({ mutes: [' a ', '', 'b'], allowHandles: ['@Foo', ' bar ', ''], strictness: 7 });
  assert.deepEqual(n.mutes, ['a', 'b']);
  assert.deepEqual(n.allowHandles, ['foo', 'bar']);
  assert.equal(n.strictness, 0.95);
  assert.equal(normaliseSettings({ strictness: 'x' }).strictness, 0.35);
  assert.equal(normaliseSettings().enabled, true);
});

test('one choice question per tweet, keep plus one label per mute', () => {
  const req = requestFor([{ id: '111', author: '@a', text: 'hi' }, { id: '222', author: '@b', text: 'yo', quoted: 'q' }], s);
  assert.deepEqual(Object.keys(req.body.questions), ['t0', 't1']);
  assert.deepEqual(req.ids, { t0: '111', t1: '222' });
  assert.deepEqual(Object.keys(req.body.questions.t0.criteria), ['keep', 'm0', 'm1']);
  assert.equal(req.body.questions.t1.criteria.m1, 'crypto shilling');
  assert.equal(req.body.state.tweets.t1.quoting, 'q');
  assert.equal(req.body.state.tweets.t0.quoting, undefined);
});

test('no request without mutes or tweets, and batches are capped', () => {
  assert.equal(requestFor([{ id: '1', text: 'x' }], normaliseSettings({ mutes: [] })), null);
  assert.equal(requestFor([], s), null);
  const many = Array.from({ length: 25 }, (_, i) => ({ id: String(i), text: 'x' }));
  assert.equal(Object.keys(requestFor(many, s).ids).length, MAX_BATCH);
});

test('verdicts hide only when keep is unlikely, and name the reason', () => {
  const answers = {
    t0: { type: 'choice', choice: 'm1', probabilities: { keep: 0.02, m0: 0.01, m1: 0.97 } },
    t1: { type: 'choice', choice: 'keep', probabilities: { keep: 0.9, m0: 0.08, m1: 0.02 } },
    t2: { type: 'choice', choice: 'm0', probabilities: { keep: 0.4, m0: 0.6, m1: 0 } },
  };
  const v = verdictsFrom(answers, { t0: 'a', t1: 'b', t2: 'c', t3: 'd' }, s);
  assert.deepEqual(v.a, { hide: true, pKeep: 0.02, reason: 'crypto shilling' });
  assert.equal(v.b.hide, false);
  assert.equal(v.c.hide, false, 'P(keep)=0.4 is above strictness 0.35');
  assert.equal(v.d, undefined, 'missing answer means no verdict (tweet shows)');
  const strict = normaliseSettings({ ...s, strictness: 0.5 });
  assert.equal(verdictsFrom(answers, { t2: 'c' }, strict).c.hide, true);
});

test('allow list matches handles with or without @, any case', () => {
  const a = normaliseSettings({ ...s, allowHandles: ['@Friend'] });
  assert.ok(isAllowed({ author: '@friend' }, a));
  assert.ok(!isAllowed({ author: '@stranger' }, a));
});

test('fingerprint changes with mutes and strictness only', () => {
  const f = settingsFingerprint(s);
  assert.equal(f, settingsFingerprint({ ...s, apiKey: 'other' }));
  assert.notEqual(f, settingsFingerprint({ ...s, strictness: 0.5 }));
  assert.notEqual(f, settingsFingerprint({ ...s, mutes: ['x'] }));
});
