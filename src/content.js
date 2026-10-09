// Runs on x.com. Every tweet the timeline renders stays invisible (it keeps its space) until Jev
// has judged it. X renders tweets a little ahead of the scroll position and Jev answers in about
// 150 ms, so normally nothing flickers. A tweet that matches a mute collapses to a one-line bar
// with a Show button; consecutive hides share one bar. A revealed tweet asks whether the hide was
// right. If Jev is slow or down, tweets show after FAIL_OPEN_MS anyway.
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

  const feedbackGiven = new Map(); // tweetId -> 'good' | 'wrong'
  const ICON = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M3 12h3l2-5 3 10 2.5-7 1.5 2h6"></path></svg>';

  function reset(article) {
    article.classList.remove('jm-pending', 'jm-hidden');
    while (article.previousElementSibling?.classList.contains('jm-ui')) article.previousElementSibling.remove();
    clearTimeout(Number(article.dataset.jmTimer));
  }

  function el(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function button(text, cls, onClick) {
    const b = el('button', cls, text);
    b.type = 'button';
    b.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); onClick(); });
    return b;
  }

  function apply(article, id) {
    const v = verdicts.get(id);
    reset(article);
    if (!v || !v.hide) return;
    if (!revealed.has(id)) {
      article.classList.add('jm-hidden');
      const bar = el('div', 'jm-ui jm-bar');
      bar.dataset.jmFor = id;
      const label = el('span', 'jm-why');
      label.innerHTML = ICON;
      label.append(el('span', 'jm-text', `Hidden · ${v.reason || 'muted'}`));
      bar.append(label, button('Show', 'jm-show', () => reveal(JSON.parse(bar.dataset.jmRun || '[]').length ? JSON.parse(bar.dataset.jmRun) : [id])));
      article.before(bar);
    } else {
      // Revealed: say why it was hidden, offer to hide it again, and ask whether the hide was right.
      const strip = el('div', 'jm-ui jm-shown');
      const top = el('div', 'jm-shown-top');
      top.append(el('span', null, `Shown · hidden for: ${v.reason || 'a mute'}`), button('Hide again', 'jm-link', () => { revealed.delete(id); apply(article, id); regroupSoon(); }));
      strip.append(top);
      const given = feedbackGiven.get(id);
      const row = el('div', 'jm-feedback');
      if (given) row.append(el('span', 'jm-thanks', given === 'wrong' ? "Noted: that one shouldn't have been hidden." : 'Noted: good hide.'));
      else {
        const send = (verdict) => {
          feedbackGiven.set(id, verdict);
          const t = read(article);
          chrome.runtime.sendMessage({ type: 'feedback', verdict, reason: v.reason, pKeep: v.pKeep,
            tweet: { id, author: t.author, text: t.text.slice(0, 280) } }).catch(() => {});
          apply(article, id);
        };
        row.append(button('Good hide', 'jm-chip', () => send('good')), button("Shouldn't have hidden this", 'jm-chip', () => send('wrong')));
      }
      strip.append(row);
      article.before(strip);
    }
  }

  function reveal(ids) {
    ids.forEach((i) => revealed.add(i));
    chrome.runtime.sendMessage({ type: 'shown', count: ids.length }).catch(() => {});
    for (const i of ids) for (const a of articlesFor(i)) apply(a, i);
    regroupSoon();
  }

  // Runs of hidden tweets with no visible tweet between them share one bar, so the bars don't
  // turn into noise of their own.
  let regroupQueued = false;
  function regroupSoon() {
    if (regroupQueued) return;
    regroupQueued = true;
    requestAnimationFrame(() => { regroupQueued = false; regroup(); });
  }
  function regroup() {
    const runs = []; let run = null;
    for (const a of document.querySelectorAll('article[data-testid="tweet"]')) {
      if (a.classList.contains('jm-hidden')) {
        const bar = a.previousElementSibling?.classList.contains('jm-bar') ? a.previousElementSibling : null;
        if (!bar) continue;
        if (!run) { run = []; runs.push(run); }
        run.push({ id: a.dataset.jmId, bar });
      } else if (!a.classList.contains('jm-pending')) run = null;
    }
    for (const r of runs) {
      const ids = r.map((x) => x.id);
      const reasons = [...new Set(ids.map((i) => verdicts.get(i)?.reason || 'muted'))];
      r.forEach((x, k) => {
        x.bar.classList.toggle('jm-merged', k > 0);
        x.bar.dataset.jmRun = JSON.stringify(ids);
        const text = x.bar.querySelector('.jm-text');
        if (text) text.textContent = ids.length > 1 ? `${ids.length} posts hidden · ${reasons.join(', ')}` : `Hidden · ${reasons[0]}`;
      });
    }
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
    if (verdicts.has(t.id)) { apply(article, t.id); regroupSoon(); return; }
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
    regroupSoon();
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
    active = !!(s && s.enabled !== false && s.apiKey && (s.picked?.length || s.customs?.length || s.mutes?.length));
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
