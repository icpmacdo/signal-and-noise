// End-to-end check of the model routes, no keys needed: loads the unpacked extension into Chrome,
// serves an X-shaped page at https://x.com/home, and answers for the models with canned stubs
// (a tiny HTTP server for the local route, CDP interception for OpenAI and pbs.twimg.com). No
// model runs anywhere; the stubs only check what the extension sends and reply by keyword.
//
//   npm run e2e:routes
import puppeteer from 'puppeteer';
import { createServer } from 'node:http';
import { resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');
const CHROME = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PIXEL = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

const TWEETS = [
  { id: '2001', handle: 'angrypundit', text: 'The other party wants to DESTROY this country.', expect: 'hide' },
  { id: '2002', handle: 'birdwatcher', text: 'A pair of kestrels nesting on the church tower again.', expect: 'show' },
  { id: '2003', handle: 'memelord', text: 'me at 3am', image: 'https://pbs.twimg.com/media/meme1?format=jpg&name=large', meme: true },
];

const cell = (t) => `<div data-testid="cellInnerDiv"><div><article data-testid="tweet" role="article">
  <div data-testid="User-Name"><span>${t.handle}</span><span>@${t.handle}</span></div>
  <a href="/${t.handle}/status/${t.id}"><time datetime="2026-10-08T12:00:00Z">2h</time></a>
  <div data-testid="tweetText">${t.text}</div>
  ${t.image ? `<div data-testid="tweetPhoto"><img alt="Image" src="${t.image}"></div>` : ''}
</article></div></div>`;
const PAGE = `<!doctype html><html><head><meta charset="utf-8"><title>Home / X</title></head>
<body><main><div aria-label="Timeline" id="tl">${TWEETS.map(cell).join('')}</div></main></body></html>`;

// Rage when the text shouts DESTROY; otherwise keep.
const ragey = (text) => /DESTROY/.test(text);

// The local route: a systemone-shaped stub.
const localSeen = [];
const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const j = JSON.parse(body || '{}');
    localSeen.push({ path: req.url, body: j });
    const hide = ragey(j.state?.tweet?.text || '');
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.end(JSON.stringify({ answers: { t0: { type: 'choice', choice: hide ? 'c_rage' : 'keep',
      probabilities: hide ? { keep: 0.1, c_rage: 0.9 } : { keep: 0.9, c_rage: 0.1 } } } }));
  });
}).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const LOCAL_URL = `http://127.0.0.1:${server.address().port}/v1/systemone`;

const fails = [];
const check = (ok, msg) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${msg}`); if (!ok) fails.push(msg); };

const browser = await puppeteer.launch({
  executablePath: CHROME, headless: true, pipe: true, enableExtensions: [ROOT],
  defaultViewport: { width: 900, height: 1100 },
});
try {
  const sw = await browser.waitForTarget((t) => t.type() === 'service_worker' && t.url().endsWith('background.js'));
  const worker = await sw.worker();
  for (const p of await browser.pages()) if (p.url().includes('options.html')) await p.close();

  // OpenAI and tweet images, answered inside the service worker's own network stack.
  const openaiSeen = [];
  const cdp = await sw.createCDPSession();
  await cdp.send('Fetch.enable', { patterns: [{ urlPattern: 'https://api.openai.com/*' }, { urlPattern: 'https://pbs.twimg.com/*' }] });
  cdp.on('Fetch.requestPaused', async ({ requestId, request }) => {
    if (request.url.startsWith('https://pbs.twimg.com/')) {
      openaiSeen.push({ image: request.url });
      await cdp.send('Fetch.fulfillRequest', { requestId, responseCode: 200,
        responseHeaders: [{ name: 'Content-Type', value: 'image/png' }], body: PIXEL.toString('base64') });
      return;
    }
    const j = JSON.parse(request.postData || '{}');
    openaiSeen.push({ auth: request.headers.Authorization, body: j });
    const parts = Array.isArray(j.input) ? j.input[0].content : [{ type: 'input_text', text: j.input }];
    const text = parts.find((p) => p.type === 'input_text')?.text || '';
    const sawImage = parts.some((p) => p.type === 'input_image' && p.image_url.startsWith('data:image/png;base64,'));
    const values = j.questions[0].choices.map((c) => c.value);
    const pick = sawImage && values.includes('c_memes') ? 'c_memes' : ragey(text) && values.includes('c_rage') ? 'c_rage' : 'keep';
    const answer = { answers: [{ type: 'choice', name: 't0', choice: pick,
      probabilities: values.map((v) => ({ value: v, probability: v === pick ? 0.9 : 0.1 / (values.length - 1) })) }] };
    await cdp.send('Fetch.fulfillRequest', { requestId, responseCode: 200,
      responseHeaders: [{ name: 'Content-Type', value: 'application/json' }], body: Buffer.from(JSON.stringify(answer)).toString('base64') });
  });

  const page = await browser.newPage();
  await page.setRequestInterception(true);
  page.on('request', (r) => {
    if (r.url().startsWith('https://x.com/')) return r.respond({ status: 200, contentType: 'text/html', body: PAGE });
    if (r.url().startsWith('https://pbs.twimg.com/')) return r.respond({ status: 200, contentType: 'image/png', body: PIXEL });
    return r.continue();
  });

  const state = () => page.$$eval('article', (as) => Object.fromEntries(as.map((a) => [a.dataset.jmId, a.classList.contains('jm-hidden')])));
  const judged = () => page.waitForFunction((n) => document.querySelectorAll('article[data-jm-id]').length >= n
    && document.querySelectorAll('article.jm-pending').length === 0, { timeout: 8000 }, TWEETS.length);
  const use = (settings) => worker.evaluate((s) => chrome.storage.local.set({ settings: s }), settings);

  // 1. Local route: no key, requests go to the configured URL in systemone shape.
  await use({ enabled: true, provider: 'local', localUrl: LOCAL_URL, localModel: 'stub-model', picked: ['rage', 'memes'] });
  await page.goto('https://x.com/home');
  await judged();
  let st = await state();
  check(st['2001'] === true, 'local: rage post hidden');
  check(st['2002'] === false && st['2003'] === false, 'local: other posts shown');
  check(localSeen.length >= 3 && localSeen.every((r) => r.body.model === 'stub-model' && r.body.questions?.t0), 'local: systemone requests with the chosen model name');
  check(localSeen.every((r) => !('c_memes' in r.body.questions.t0.criteria)), "local: Memes isn't asked about on a text-only route");

  // 2. OpenAI route: key sent, the meme's picture goes along as a data: URL, Memes hides it.
  await use({ enabled: true, provider: 'openai', keys: { openai: 'sk-test' }, sendImages: true, picked: ['rage', 'memes'] });
  await page.goto('https://x.com/home');
  await judged();
  st = await state();
  check(st['2001'] === true, 'openai: rage post hidden');
  check(st['2003'] === true, 'openai: meme hidden because the model saw the picture');
  check(st['2002'] === false, 'openai: ordinary post shown');
  const calls = openaiSeen.filter((x) => x.body);
  check(calls.length >= 3 && calls.every((c) => c.auth === 'Bearer sk-test'), 'openai: key sent as a bearer token');
  check(openaiSeen.some((x) => x.image?.includes('name=small')), 'openai: images fetched at small size');

  // 3. Images off: the meme isn't judged as one (Memes drops out), so it shows.
  await use({ enabled: true, provider: 'openai', keys: { openai: 'sk-test' }, sendImages: false, picked: ['rage', 'memes'] });
  await page.goto('https://x.com/home');
  await judged();
  st = await state();
  check(st['2003'] === false, 'openai, images off: meme shown');

  // 4. A broken route fails open.
  await use({ enabled: true, provider: 'local', localUrl: 'http://127.0.0.1:1/v1/systemone', picked: ['rage'] });
  await page.goto('https://x.com/home');
  await judged();
  st = await state();
  check(Object.values(st).every((h) => h === false), 'unreachable server: everything shows');

  // 5. Settings page: the picker switches the fields, and the old single key shows up as TypeSafe's.
  await use({ enabled: true, apiKey: 'apikey_legacy', picked: ['memes'] });
  const opts = await browser.newPage();
  const errors = [];
  opts.on('pageerror', (e) => errors.push(e.message));
  await opts.goto(`chrome-extension://${new URL(sw.url()).host}/src/options.html`);
  await opts.waitForSelector('#provider option');
  check(await opts.$eval('#key', (k) => k.value) === 'apikey_legacy', 'settings: old key appears under TypeSafe');
  check(await opts.$eval('#common .blind', (b) => b.textContent.includes('Memes')), 'settings: Memes is marked as needing images on Jev');
  await opts.select('#provider', 'local');
  check(await opts.$eval('#local-row', (r) => !r.hidden), 'settings: local shows the URL and model fields');
  await opts.select('#provider', 'openai');
  check(await opts.$eval('#images-row', (r) => !r.hidden) && await opts.$eval('#key', (k) => k.value === ''), 'settings: OpenAI shows the images switch and its own empty key');
  await opts.screenshot({ path: resolve(ROOT, 'shots/options-model.png'), fullPage: true });
  check(!errors.length, `settings: no page errors${errors.length ? `: ${errors.join('; ')}` : ''}`);
} finally {
  await browser.close();
  server.close();
}
if (fails.length) { console.log(`\n${fails.length} failed`); process.exit(1); }
console.log('\nall route checks passed');
