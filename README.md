# Signal & Noise

A Chrome extension that hides posts you don't want on your X timeline. Tap common kinds of noise
as bubbles (political rage bait, crypto shilling, engagement bait, spoilers…) or type your own in
plain words ("anything about the Oilers"), and [Jev](https://typesafe.ai) judges each tweet against
them, one-shot, before it scrolls into view. Matches fold into a one-line bar that says why; runs of
hidden posts share one bar. After **Show**, a post asks "Good hide / Shouldn't have hidden this";
those answers are kept locally (`feedbackLog`) as the start of a real-world eval set.

## Install (unpacked)

1. `chrome://extensions` → turn on **Developer mode** → **Load unpacked** → pick this folder.
2. The settings page opens. Under **Model**, pick TypeSafe Jev (default), OpenAI Decisions, or a local/self-hosted
   server, and paste its key. Tap bubbles or add your own. Changes save as you go.
3. Open x.com.

## How it works

- `src/content.js` finds each `article[data-testid="tweet"]` as X renders it and keeps it
  invisible (its space is kept, so nothing jumps) until Jev answers. X renders a little ahead of
  the scroll position and Jev answers in about 150–200 ms, so most tweets are judged before you
  reach them. If Jev is slow or down, tweets show after 2 s anyway.
- `src/background.js` holds the key and sends one tweet per request (in parallel; batching lets neighbours change verdicts) to
  `api.typesafe.ai/v1/systemone`. Each tweet gets one `choice` question: `keep` plus one label per
  mute, on pinned model `jev-1.13.0`. A tweet is hidden when P(keep) is below the strictness setting (default 35%). Verdicts are
  cached per tweet id.
- Other routes: OpenAI's Decisions API (`gpt-6-luna`), which also sees up to two post images, so the
  Memes bubble only works there; or any server speaking the `/v1/systemone` protocol at a URL you
  set (localhost is allowed up front, other hosts ask for permission when you press Test).
- `src/wire.js` builds the request for each route and reads the answers. It is pure code, with unit
  tests in `test/`. `src/ask.js` makes the call, shared by the background worker and the settings page.
- Tweets from accounts on the "always show" list are never sent to Jev. The tweet you opened
  directly (`/status/<id>`) is never hidden.

## Privacy

Tweet text, the author's handle and image alt text are sent to the model you picked for judging.
On OpenAI with images on, the post's pictures are sent too. Nothing else is sent. Keys stay in
`chrome.storage.local`.

## Develop

```sh
npm test        # unit tests (node --test)
npm run e2e     # real Jev call: loads the extension into Chrome, serves a fake X timeline at
                # https://x.com/home via request interception, checks what gets hidden; needs
                # TYPESAFE_API_KEY or ~/.config/typesafe/api_key; screenshots go to shots/
npm run e2e:routes  # no keys: same fake timeline, with stub answers for the local and OpenAI
                    # routes; checks requests, image sending, fail-open and the settings page
npm run zip     # signal-and-noise.zip for the Chrome Web Store
```

## Decision pages

`decisions/*.src.html` build (`node decisions/build.mjs`) into interactive pages that use synthetic
tweets (`eval/synthetic/`) scored by Jev: Threshold Lab (designs, lines, which mutes ship), Run Planner
(how to run the real eval), Taste Test (your own calls → your own lines). `eval/` holds the real-feed
harness; its data stays local and gitignored.
