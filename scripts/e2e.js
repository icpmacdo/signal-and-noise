// End-to-end check against the real Jev API: loads the unpacked extension into Chrome for
// Testing, serves a page shaped like X's timeline at https://x.com/home (request interception,
// nothing touches the real site), and checks which tweets end up hidden.
//
//   TYPESAFE_API_KEY=… npm run e2e      (or key in ~/.config/typesafe/api_key)
import puppeteer from 'puppeteer';
import { readFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');
const key = process.env.TYPESAFE_API_KEY?.trim()
  || readFileSync(join(homedir(), '.config/typesafe/api_key'), 'utf8').trim();

// Branded Chrome ignores --load-extension, so the extension goes in over CDP (enableExtensions).
const CHROME = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const TWEETS = [
  { id: '1001', handle: 'rustacean', text: 'Shipped a small crate that parses EXIF 3x faster. Benchmarks and the trick in the thread.', expect: 'show' },
  { id: '1002', handle: 'angrypundit', text: "The other party wants to DESTROY this country. If you can't see it, you're part of the problem. 🤬", expect: 'hide' },
  { id: '1003', handle: 'moonboi', text: '🚀🚀 $PEPE2 is going 100x by Friday. Not financial advice. Get in before it is too late 👇', expect: 'hide' },
  { id: '1004', handle: 'baker_jo', text: 'Third attempt at a sourdough loaf and it finally has an open crumb. Photo below.', expect: 'hide' }, // custom mute
  { id: '1005', handle: 'growthguru', text: "Like if you agree, ignore if you're a hater 🙏 Who's still up? Reply with your city!", expect: 'hide' },
  { id: '1006', handle: 'policywonk', text: 'New CBO report on the infrastructure bill: cost estimates revised down 4%. Table on page 12.', expect: 'show' },
];
// A quote card carries its own User-Name box, as on x.com.
const QUOTES = [
  { id: '1010', handle: 'tomek_k', text: 'aged like milk, I know...', qhandle: 'tomek_k', qtext: "I'm quite unhappy with much of what a big AI lab does. I am very happy that I'm allowed to say that.", expect: 'show' },
  { id: '1011', handle: 'snarky_sam', text: 'aged like milk lmao. imagine posting this with a straight face 🤡', qhandle: 'tomek_k', qtext: "I'm quite unhappy with much of what a big AI lab does. I am very happy that I'm allowed to say that.", expect: 'hide' },
];
const LATE = [ // rendered after load, like X's lazy timeline
  { id: '1007', handle: 'airdropking', text: 'FREE AIRDROP 🎁 Connect your wallet at the link in bio to claim 5000 tokens before midnight!!', expect: 'hide' },
  { id: '1008', handle: 'birdwatcher', text: 'A pair of kestrels nesting on the church tower again this spring.', expect: 'show' },
];

const cell = (t) => `<div data-testid="cellInnerDiv"><div><article data-testid="tweet" role="article">
  <div data-testid="User-Name"><span>${t.handle}</span><span>@${t.handle}</span></div>
  <a href="/${t.handle}/status/${t.id}"><time datetime="2026-10-08T12:00:00Z">2h</time></a>
  <div data-testid="tweetText">${t.text}</div>
</article></div></div>`;

const quoteCell = (t) => `<div data-testid="cellInnerDiv"><div><article data-testid="tweet" role="article">
  <div data-testid="User-Name"><span>${t.handle}</span><span>@${t.handle}</span></div>
  <a href="/${t.handle}/status/${t.id}"><time datetime="2026-10-08T12:00:00Z">1h</time></a>
  <div data-testid="tweetText">${t.text}</div>
  <div role="link"><div data-testid="User-Name"><span>${t.qhandle}</span><span>@${t.qhandle}</span></div>
  <div data-testid="tweetText">${t.qtext}</div></div>
</article></div></div>`;

const PAGE = `<!doctype html><html><head><meta charset="utf-8"><title>Home / X</title>
<style>body{margin:0;background:#000;color:#e7e9ea;font:15px -apple-system,sans-serif}
main{width:600px;margin:0 auto;border-left:1px solid #2f3336;border-right:1px solid #2f3336}
article{padding:12px 16px;border-bottom:1px solid #2f3336}
[data-testid=User-Name]{font-weight:700;margin-bottom:4px}[data-testid=User-Name] span+span{color:#71767b;font-weight:400;margin-left:6px}
a{color:#71767b;font-size:13px}</style></head>
<body><main><div aria-label="Timeline" id="tl">${TWEETS.map(cell).join('')}</div></main>
<script>window.__late = ${JSON.stringify(LATE.map(cell))}; window.__quotes = ${JSON.stringify(QUOTES.map(quoteCell))};</script></body></html>`;

const fails = [];
const check = (ok, msg) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${msg}`); if (!ok) fails.push(msg); };

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  pipe: true,
  enableExtensions: [ROOT],
  args: ['--window-size=900,1100'],
  defaultViewport: { width: 900, height: 1100 },
});
try {
  const sw = await browser.waitForTarget((t) => t.type() === 'service_worker' && t.url().endsWith('background.js'));
  const worker = await sw.worker();
  // Close the options tab the install opens.
  for (const p of await browser.pages()) if (p.url().includes('options.html')) await p.close();

  const page = await browser.newPage();
  await page.setRequestInterception(true);
  page.on('request', (r) => (r.url().startsWith('https://x.com/')
    ? r.respond({ status: 200, contentType: 'text/html', body: PAGE })
    : r.continue()));

  // 1. No key: everything must show (fail open, no pending state).
  await worker.evaluate(() => chrome.storage.local.set({ settings: { enabled: true, apiKey: '', picked: ['rage'] } }));
  await page.goto('https://x.com/home');
  await new Promise((r) => setTimeout(r, 800));
  const noKey = await page.$$eval('article', (as) => as.filter((a) => a.classList.contains('jm-pending') || a.classList.contains('jm-hidden')).length);
  check(noKey === 0, 'without a key nothing is hidden or held back');

  // 2. With the key, the three default bubbles and one typed mute.
  await worker.evaluate((apiKey) => chrome.storage.local.set({ settings: {
    enabled: true, apiKey, allowHandles: [], picked: ['rage', 'crypto', 'engage'], customs: ['Home baking and bread'],
  } }), key);
  const t0 = Date.now();
  await page.goto('https://x.com/home');
  await page.waitForFunction(() => document.querySelectorAll('article.jm-pending').length === 0
    && document.querySelectorAll('article[data-jm-id]').length >= 6, { timeout: 5000 });
  console.log(`     first screen judged in ${Date.now() - t0} ms (incl. page load)`);

  const state = () => page.$$eval('article', (as) => Object.fromEntries(as.map((a) => [a.dataset.jmId,
    { hidden: a.classList.contains('jm-hidden'), bar: a.previousElementSibling?.classList.contains('jm-bar') ? a.previousElementSibling.textContent : null }])));
  let st = await state();
  for (const t of TWEETS) check((st[t.id]?.hidden ? 'hide' : 'show') === t.expect, `@${t.handle} ${t.expect === 'hide' ? 'hidden' : 'shown'}${st[t.id]?.bar ? ` — "${st[t.id].bar.replace('Show', '').trim()}"` : ''}`);

  const bars = () => page.$$eval('.jm-bar:not(.jm-merged)', (bs) => bs.map((b) => b.textContent.replace('Show', '').trim()));
  let visible = await bars();
  check(visible.length === 1 && /^4 posts hidden · /.test(visible[0]), `four hides in a row share one bar — "${visible[0]}"`);
  check(/Home baking and bread/.test(visible[0] || ''), 'a typed mute is judged one-shot and named on the bar');

  mkdirSync(join(ROOT, 'shots'), { recursive: true });
  await page.screenshot({ path: join(ROOT, 'shots/timeline.png') });

  // 3. Lazily rendered tweets get judged too.
  await page.evaluate(() => { const tl = document.getElementById('tl'); for (const h of window.__late) tl.insertAdjacentHTML('beforeend', h); });
  await page.waitForFunction(() => document.querySelectorAll('article[data-jm-id]').length >= 8
    && document.querySelectorAll('article.jm-pending').length === 0, { timeout: 5000 });
  st = await state();
  for (const t of LATE) check((st[t.id]?.hidden ? 'hide' : 'show') === t.expect, `late @${t.handle} ${t.expect === 'hide' ? 'hidden' : 'shown'}`);

  visible = await bars();
  check(visible.length === 2, `a hide after a visible tweet gets its own bar (${visible.length} bars)`);

  // 3b. Quote tweets: quoting yourself isn't a dunk; quote-dunking someone else is.
  await worker.evaluate(async () => {
    const { settings } = await chrome.storage.local.get('settings');
    await chrome.storage.local.set({ settings: { ...settings, picked: [...settings.picked, 'dunk'] } });
  });
  await new Promise((r) => setTimeout(r, 1200));
  await page.evaluate(() => { const tl = document.getElementById('tl'); for (const h of window.__quotes) tl.insertAdjacentHTML('beforeend', h); });
  await page.waitForFunction(() => document.querySelectorAll('article[data-jm-id="1010"], article[data-jm-id="1011"]').length === 2
    && document.querySelectorAll('article.jm-pending').length === 0, { timeout: 6000 });
  st = await state();
  for (const t of QUOTES) check((st[t.id]?.hidden ? 'hide' : 'show') === t.expect, `quote: @${t.handle} quoting @${t.qhandle} ${t.expect === 'hide' ? 'hidden as a dunk' : 'shown'}`);
  await worker.evaluate(async () => {
    const { settings } = await chrome.storage.local.get('settings');
    await chrome.storage.local.set({ settings: { ...settings, picked: settings.picked.filter((x) => x !== 'dunk') } });
  });
  await page.evaluate(() => { document.querySelectorAll('article[data-jm-id="1010"], article[data-jm-id="1011"]').forEach((a) => a.closest('[data-testid=cellInnerDiv]').remove()); });
  await new Promise((r) => setTimeout(r, 1500));
  await page.waitForFunction(() => document.querySelectorAll('article.jm-pending').length === 0, { timeout: 6000 });

  // 3c. Videos: a post with a video player hides under the Videos bubble; a text post doesn't.
  await worker.evaluate(async () => {
    const { settings } = await chrome.storage.local.get('settings');
    await chrome.storage.local.set({ settings: { ...settings, picked: [...settings.picked, 'video'] } });
  });
  await new Promise((r) => setTimeout(r, 1200));
  await page.evaluate(() => {
    const tl = document.getElementById('tl');
    const mk = (id, h, text, video) => `<div data-testid="cellInnerDiv"><div><article data-testid="tweet" role="article">
      <div data-testid="User-Name"><span>${h}</span><span>@${h}</span></div>
      <a href="/${h}/status/${id}"><time datetime="2026-10-08T12:00:00Z">1h</time></a>
      <div data-testid="tweetText">${text}</div>${video ? '<div data-testid="videoPlayer"><video></video></div>' : ''}</article></div></div>`;
    tl.insertAdjacentHTML('beforeend', mk('1012', 'clipper', 'watch this sunset timelapse from the ridge', true) + mk('1013', 'writer', 'wrote up how we cut our build times in half', false));
  });
  await page.waitForFunction(() => document.querySelectorAll('article[data-jm-id="1012"], article[data-jm-id="1013"]').length === 2
    && document.querySelectorAll('article.jm-pending').length === 0, { timeout: 6000 });
  st = await state();
  check(st['1012']?.hidden === true, 'Videos bubble hides a post with a video player');
  check(st['1013']?.hidden === false, 'Videos bubble leaves a text post alone');
  await worker.evaluate(async () => {
    const { settings } = await chrome.storage.local.get('settings');
    await chrome.storage.local.set({ settings: { ...settings, picked: settings.picked.filter((x) => x !== 'video') } });
  });
  await page.evaluate(() => { document.querySelectorAll('article[data-jm-id="1012"], article[data-jm-id="1013"]').forEach((a) => a.closest('[data-testid=cellInnerDiv]').remove()); });
  await new Promise((r) => setTimeout(r, 1500));
  await page.waitForFunction(() => document.querySelectorAll('article.jm-pending').length === 0, { timeout: 6000 });

  // 4. Show on the grouped bar reveals the whole run, each with feedback chips.
  await page.click('.jm-bar:not(.jm-merged) .jm-show');
  await page.waitForFunction(() => document.querySelectorAll('.jm-shown').length >= 4, { timeout: 2000 }).catch(() => {});
  st = await state();
  check(Object.values(st).filter((v) => v.hidden).length === 1, 'Show on a grouped bar reveals all four');
  check(await page.$$eval('.jm-shown', (x) => x.length) === 4, 'each revealed post says why it was hidden and asks for feedback');
  await page.screenshot({ path: join(ROOT, 'shots/revealed.png') });

  // Feedback: "Shouldn't have hidden this" on the baking post is logged with its reason.
  await page.evaluate(() => [...document.querySelector('article[data-jm-id="1004"]').previousElementSibling.querySelectorAll('.jm-chip')].find((b) => /Shouldn/.test(b.textContent)).click());
  await new Promise((r) => setTimeout(r, 300));
  const { feedbackLog } = await worker.evaluate(() => chrome.storage.local.get('feedbackLog'));
  const last = feedbackLog?.at(-1);
  check(last?.verdict === 'wrong' && last?.reason === 'Home baking and bread' && last?.tweet?.id === '1004', 'feedback is recorded with the tweet and the mute that hid it');
  check(/Noted/.test(await page.$eval('article[data-jm-id="1004"]', (a) => a.previousElementSibling.textContent)), 'the chip row turns into a thank-you');

  // Hide again puts it back behind a bar.
  await page.evaluate(() => [...document.querySelector('article[data-jm-id="1002"]').previousElementSibling.querySelectorAll('button')].find((b) => b.textContent === 'Hide again').click());
  check(await page.$eval('article[data-jm-id="1002"]', (a) => a.classList.contains('jm-hidden')), 'Hide again hides it');

  // 5. X recycles cells: swap a shown tweet's contents for a shilling one.
  await page.evaluate(() => {
    const a = document.querySelector('article[data-jm-id="1006"]');
    a.querySelector('a').setAttribute('href', '/moon2/status/1009');
    a.querySelector('[data-testid=User-Name]').innerHTML = '<span>moon2</span><span>@moon2</span>';
    a.querySelector('[data-testid=tweetText]').textContent = 'Buy $DOGE2 now, guaranteed 50x, this is your last chance to get rich 🚀';
  });
  await page.waitForFunction(() => document.querySelector('article[data-jm-id="1009"]:not(.jm-pending)'), { timeout: 5000 });
  check(await page.$eval('article[data-jm-id="1009"]', (a) => a.classList.contains('jm-hidden')), 'recycled cell is re-judged and hidden');

  // 6. Pausing shows everything again.
  await worker.evaluate(async () => {
    const { settings } = await chrome.storage.local.get('settings');
    await chrome.storage.local.set({ settings: { ...settings, enabled: false } });
  });
  await new Promise((r) => setTimeout(r, 300));
  check(await page.$$eval('article.jm-hidden, .jm-ui', (x) => x.length) === 0, 'turning it off unhides everything');

  const { stats } = await worker.evaluate(() => chrome.storage.local.get('stats'));
  check(stats?.hidden >= 4, `popup tally recorded ${stats?.hidden} hidden of ${stats?.judged} judged`);

  // Popup screenshot.
  const extId = new URL(sw.url()).host;
  const popup = await browser.newPage();
  await popup.setViewport({ width: 360, height: 560 });
  await popup.goto(`chrome-extension://${extId}/src/popup.html`);
  await popup.screenshot({ path: join(ROOT, 'shots/popup.png') });

  // 6b. Back on from the popup switch (it rewrites settings): the timeline filters again.
  await popup.click('#enabled');
  await page.bringToFront();
  await page.waitForFunction(() => document.querySelectorAll('article.jm-hidden').length > 0
    && document.querySelectorAll('article.jm-pending').length === 0, { timeout: 6000 }).catch(() => {});
  check(await page.$$eval('article.jm-hidden', (x) => x.length) > 0, 'turning it back on from the popup hides again');
  const opts = await browser.newPage();
  await worker.evaluate(async () => {
    const { settings } = await chrome.storage.local.get('settings');
    await chrome.storage.local.set({ settings: { ...settings, enabled: true } });
  });
  await opts.setViewport({ width: 1280, height: 1000 });
  await opts.goto(`chrome-extension://${extId}/src/options.html`);
  await opts.waitForFunction(() => /judged by TypeSafe Jev/.test(document.getElementById('preview-note').textContent), { timeout: 6000 }).catch(() => {});
  check(/judged by TypeSafe Jev/.test(await opts.$eval('#preview-note', (n) => n.textContent)), `settings preview runs on Jev — "${await opts.$eval('#preview-sum', (n) => n.textContent)}"`);
  // Tap a bubble: it saves straight away.
  await opts.evaluate(() => [...document.querySelectorAll('#common .bubble')].find((b) => b.textContent.includes('Sports')).click());
  await new Promise((r) => setTimeout(r, 500));
  const saved = await worker.evaluate(() => chrome.storage.local.get('settings'));
  check(saved.settings.picked.includes('sports'), 'tapping a bubble saves it');
  await opts.screenshot({ path: join(ROOT, 'shots/options.png'), fullPage: true });
  await opts.setViewport({ width: 420, height: 900 });
  await new Promise((r) => setTimeout(r, 200));
  check(await opts.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'settings page has no sideways scroll at 420 px');
} finally {
  await browser.close();
}
console.log(fails.length ? `\n${fails.length} failed` : '\nall passed');
process.exit(fails.length ? 1 : 0);
