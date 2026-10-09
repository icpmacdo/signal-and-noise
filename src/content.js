// Runs on x.com. Every tweet the timeline renders stays invisible (it keeps its space) until Jev
// has judged it. X renders tweets a little ahead of the scroll position and Jev answers in about
// 150 ms, so normally nothing flickers. A tweet that matches a mute collapses to a one-line bar
// with a Show button. If Jev is slow or down, tweets show after FAIL_OPEN_MS anyway.
(() => {
  const FAIL_OPEN_MS = 2000;
  const FLUSH_MS = 60;

  let active = false;            // enabled, key set, at least one mute
  const verdicts = new Map();    // tweetId -> verdict
  const revealed = new Set();    // tweetIds the reader chose to show
  const counted = new Set();     // tweetIds already tallied
  const queue = new Map();       // tweetId -> tweet payload
  let flushTimer = null;

  // ---- reading a tweet out of X's DOM ----------------------------------------------------

  function tweetId(article) {
    for (const a of article.querySelectorAll('a[href*="/status/"]')) {
      if (!a.querySelector('time')) continue;
      const m = a.getAttribute('href').match(/\/status\/(\d+)/);
      if (m) return m[1];
    }
    return null; // promoted posts often have no permalink; we hash their text instead
  }

  function hash(s) {
    let h = 5381;
    for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
    return `h${(h >>> 0).toString(36)}`;
  }

  function read(article) {
    const nameBox = article.querySelector('[data-testid="User-Name"]');
    const handle = nameBox && [...nameBox.querySelectorAll('span')]
      .map((s) => s.textContent.trim()).find((t) => /^@\w+$/.test(t));
    const texts = [...article.querySelectorAll('[data-testid="tweetText"]')].map((n) => n.innerText.trim());
    const media = [...article.querySelectorAll('[data-testid="tweetPhoto"] img[alt]')]
      .map((i) => i.getAttribute('alt')).filter((a) => a && a !== 'Image');
    const context = article.querySelector('[data-testid="socialContext"]')?.innerText.trim();
    const promoted = /\bPromoted\b|\bAd\b/.test(article.querySelector('[data-testid="placementTracking"]')?.innerText || '')
      || !!article.querySelector('[data-testid="placementTracking"]');
    const t = {
      author: handle || nameBox?.innerText.split('\n')[0] || 'unknown',
      text: texts[0] || '',
      quoted: texts[1] || '',
      media,
      context: promoted ? 'promoted post (ad)' : context || '',
    };
    t.id = tweetId(article) || hash(`${t.author}|${t.text}|${t.quoted}`);
    return t;
  }

  function focalId() {
    const m = location.pathname.match(/\/status\/(\d+)/);
    return m ? m[1] : null;
  }

  // ---- showing and hiding -----------------------------------------------------------------

  function reset(article) {
    article.classList.remove('jm-pending', 'jm-hidden');
    if (article.previousElementSibling?.classList.contains('jm-bar')) article.previousElementSibling.remove();
    clearTimeout(Number(article.dataset.jmTimer));
  }

  function apply(article, id) {
    const v = verdicts.get(id);
    reset(article);
    if (!v || !v.hide || revealed.has(id)) return;
    article.classList.add('jm-hidden');
    const bar = document.createElement('div');
    bar.className = 'jm-bar';
    const label = document.createElement('span');
    label.textContent = `Hidden by Jev${v.reason ? ` · ${v.reason}` : ''}`;
    label.title = `Chance you'd want to see it: ${Math.round((v.pKeep ?? 0) * 100)}%`;
    const show = document.createElement('button');
    show.type = 'button';
    show.textContent = 'Show';
    show.addEventListener('click', (e) => {
      e.preventDefault(); e.stopPropagation();
      revealed.add(id);
      apply(article, id);
    });
    bar.append(label, show);
    article.before(bar);
  }

  function articlesFor(id) {
    return document.querySelectorAll(`article[data-jm-id="${CSS.escape(id)}"]`);
  }

  function visit(article) {
    const quick = tweetId(article);
    if (quick && article.dataset.jmId === quick) return;
    const t = read(article);
    if (article.dataset.jmId === t.id) return; // already handled, same tweet
    reset(article);
    article.dataset.jmId = t.id;
    if (!active || t.id === focalId() || (!t.text && !t.quoted && !t.media.length)) return;
    if (verdicts.has(t.id)) { apply(article, t.id); return; }
    article.classList.add('jm-pending');
    article.dataset.jmTimer = String(setTimeout(() => article.classList.remove('jm-pending'), FAIL_OPEN_MS));
    queue.set(t.id, t);
    if (!flushTimer) flushTimer = setTimeout(flush, FLUSH_MS);
  }

  async function flush() {
    flushTimer = null;
    const tweets = [...queue.values()];
    queue.clear();
    if (!tweets.length) return;
    let res;
    try {
      res = await chrome.runtime.sendMessage({ type: 'judge', tweets });
    } catch {
      res = { verdicts: {} }; // extension reloaded underneath us: fail open
    }
    const reasons = [];
    for (const t of tweets) {
      const v = res?.verdicts?.[t.id];
      if (v) {
        verdicts.set(t.id, v);
        if (v.hide && !counted.has(t.id)) { counted.add(t.id); reasons.push(v.reason || 'other'); }
      }
      for (const a of articlesFor(t.id)) apply(a, t.id);
    }
    const tabHidden = counted.size;
    chrome.runtime.sendMessage({ type: 'tally', judged: Object.keys(res?.verdicts || {}).length, reasons, tabHidden })
      .catch(() => {});
  }

  function scan(root = document) {
    root.querySelectorAll('article[data-testid="tweet"]').forEach(visit);
  }

  // ---- settings -----------------------------------------------------------------------------

  function setActive(s) {
    const was = active;
    active = !!(s && s.enabled !== false && s.apiKey && s.mutes?.length);
    if (was === active && !(active && s)) return;
    verdicts.clear(); // mutes may have changed; re-judge what's on screen
    document.querySelectorAll('article[data-jm-id]').forEach((a) => { reset(a); delete a.dataset.jmId; });
    scan();
  }

  chrome.storage.local.get('settings').then(({ settings }) => setActive(settings));
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.settings) setActive(changes.settings.newValue);
  });

  // X renders the timeline lazily and recycles cells, so watch everything under <body>.
  new MutationObserver((records) => {
    for (const r of records) {
      const art = r.target.closest?.('article[data-testid="tweet"]');
      if (art) visit(art);
      for (const n of r.addedNodes) if (n.nodeType === 1) {
        if (n.matches('article[data-testid="tweet"]')) visit(n); else scan(n);
      }
    }
  }).observe(document.body || document.documentElement, { childList: true, subtree: true });
})();
