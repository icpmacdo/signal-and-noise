# Signal & Noise

A Chrome extension that hides posts you don't want on your X timeline. You list what you don't
want in plain words ("rage bait about politics", "crypto shilling", "engagement bait"), and
[Jev](https://typesafe.ai) judges each tweet before it scrolls into view. Matches fold into a
one-line bar that says why, with a **Show** button.

## Install (unpacked)

1. `chrome://extensions` → turn on **Developer mode** → **Load unpacked** → pick this folder.
2. The settings page opens. Paste a TypeSafe API key, edit the mute list, click **Test key**, then **Save**.
3. Open x.com.

## How it works

- `src/content.js` finds each `article[data-testid="tweet"]` as X renders it and keeps it
  invisible (its space is kept, so nothing jumps) until Jev answers. X renders a little ahead of
  the scroll position and Jev answers in about 150–200 ms, so most tweets are judged before you
  reach them. If Jev is slow or down, tweets show after 2 s anyway.
- `src/background.js` holds the key and sends up to 10 tweets per request to
  `api.typesafe.ai/v1/systemone`. Each tweet gets one `choice` question: `keep` plus one label per
  mute. A tweet is hidden when P(keep) is below the strictness setting (default 35%). Verdicts are
  cached per tweet id.
- `src/wire.js` builds the request and reads the answers. It is pure code, with unit tests in `test/`.
- Tweets from accounts on the "always show" list are never sent to Jev. The tweet you opened
  directly (`/status/<id>`) is never hidden.

## Privacy

Tweet text, the author's handle and image alt text are sent to TypeSafe for judging. Nothing
else is sent. The key stays in `chrome.storage.local`.

## Develop

```sh
npm test        # unit tests (node --test)
npm run e2e     # real Jev call: loads the extension into Chrome, serves a fake X timeline at
                # https://x.com/home via request interception, checks what gets hidden; needs
                # TYPESAFE_API_KEY or ~/.config/typesafe/api_key; screenshots go to shots/
npm run zip     # signal-and-noise.zip for the Chrome Web Store
```
