import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  normaliseSettings, requestFor, verdictsFrom, isAllowed, settingsFingerprint, mutesOf, COMMON, HIDE_BELOW,
} from '../src/wire.js';

const s = normaliseSettings({ picked: ['rage', 'crypto'], customs: ['Spoilers for Severance'] });

test('settings are cleaned up', () => {
  const n = normaliseSettings({ picked: ['rage', 'nope', 'rage'], customs: [' a ', '', 'A', 'b'], allowHandles: ['@Foo', ' bar ', ''] });
  assert.deepEqual(n.picked, ['rage'], 'unknown and duplicate bubbles dropped');
  assert.deepEqual(n.customs, ['a', 'b'], 'blank and case-duplicate customs dropped');
  assert.deepEqual(n.allowHandles, ['foo', 'bar']);
  const d = normaliseSettings();
  assert.equal(d.enabled, true);
  assert.deepEqual(d.picked, ['rage', 'crypto', 'engage'], 'three defaults on for new users');
  assert.equal('strictness' in d, false, 'no per-user strictness any more');
});

test('old free-text mutes migrate onto bubbles and customs', () => {
  const n = normaliseSettings({ mutes: ['Rage bait or outrage-farming about politics', 'posts about the Oilers'], strictness: 0.4 });
  assert.deepEqual(n.picked, ['rage']);
  assert.deepEqual(n.customs, ['posts about the Oilers']);
  assert.equal('mutes' in n, false);
});

test('every common bubble has a unique id, a label and a hint for Jev', () => {
  assert.equal(new Set(COMMON.map((c) => c.id)).size, COMMON.length);
  for (const c of COMMON) assert.ok(c.label && c.hint, c.id);
});

test('one tweet per request; criteria are keep + bubbles (label: hint) + customs verbatim', () => {
  const req = requestFor([{ id: '222', author: '@b', text: 'yo', quoted: 'q' }, { id: '333', text: 'ignored' }], s);
  assert.deepEqual(Object.keys(req.body.questions), ['t0'], 'never batch: neighbours change verdicts');
  assert.deepEqual(req.ids, { t0: '222' });
  const crit = req.body.questions.t0.criteria;
  assert.deepEqual(Object.keys(crit), ['keep', 'c_rage', 'c_crypto', 'u0']);
  assert.match(crit.c_rage, /^Political rage bait: /);
  assert.equal(crit.u0, 'Spoilers for Severance');
  assert.equal(req.body.state.tweet.quoting, 'q');
});

test('no request without mutes or tweets', () => {
  assert.equal(requestFor([{ id: '1', text: 'x' }], normaliseSettings({ picked: [], customs: [] })), null);
  assert.equal(requestFor([], s), null);
});

test('hide when a mute beats keep; the bar names the mute the reader picked or typed', () => {
  const ids = { t0: 'a' };
  const v1 = verdictsFrom({ t0: { type: 'choice', choice: 'u0', probabilities: { keep: 0.1, c_rage: 0.0, c_crypto: 0.0, u0: 0.9 } } }, ids, s);
  assert.deepEqual(v1.a, { hide: true, pKeep: 0.1, reason: 'Spoilers for Severance' });
  const v2 = verdictsFrom({ t0: { type: 'choice', choice: 'c_crypto', probabilities: { keep: 0.02, c_rage: 0.01, c_crypto: 0.97, u0: 0 } } }, ids, s);
  assert.equal(v2.a.reason, 'Crypto & memecoin shilling');
  const v3 = verdictsFrom({ t0: { type: 'choice', choice: 'keep', probabilities: { keep: HIDE_BELOW + 0.01, c_rage: 0.49, c_crypto: 0, u0: 0 } } }, ids, s);
  assert.equal(v3.a.hide, false);
  assert.equal(verdictsFrom({}, ids, s).a, undefined, 'missing answer means no verdict (tweet shows)');
});

test('mute labels and keys line up', () => {
  assert.deepEqual(mutesOf(s).map((m) => m.label), ['Political rage bait', 'Crypto & memecoin shilling', 'Spoilers for Severance']);
});

test('allow list matches handles with or without @, any case', () => {
  const a = normaliseSettings({ ...s, allowHandles: ['@Friend'] });
  assert.ok(isAllowed({ author: '@friend' }, a));
  assert.ok(!isAllowed({ author: '@stranger' }, a));
});

test('fingerprint changes with mutes only', () => {
  const f = settingsFingerprint(s);
  assert.equal(f, settingsFingerprint({ ...s, apiKey: 'other', enabled: false }));
  assert.notEqual(f, settingsFingerprint({ ...s, customs: ['x'] }));
  assert.notEqual(f, settingsFingerprint({ ...s, picked: ['rage'] }));
});
