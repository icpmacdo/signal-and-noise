# Signal & Noise for macOS (experimental)

The extension's idea applied to the whole screen. A menu-bar app watches every display and blurs
the parts that match your bubbles (ads, memes, graphic violence, anything you type). It works from
pixels only, so it runs in any app. Hover over a mask to peek through it; click to show it.

Judging uses OpenAI's [Decisions API](https://developers.openai.com/api/docs/guides/decisions)
(`gpt-6-luna`, `POST /v1/decisions`). It's billed for input only ($0.10 per million tokens), so many
questions about one picture cost about the same as one. Optionally, masks are reshaped with Meta's
SAM 3, hosted on [fal.ai](https://fal.ai/models/fal-ai/sam-3/image) ($0.005 per call). No model
runs on this Mac.

## Run it

```sh
cd os
./build.sh                       # builds "build/Signal & Noise OS.app"
open "build/Signal & Noise OS.app"
```

1. macOS asks for **Screen Recording** permission (System Settings › Privacy & Security). Allow it
   and reopen the app. `build.sh` signs with your Apple Development identity if you have one,
   so the permission survives rebuilds; with ad-hoc signing macOS asks again after each rebuild.
2. Menu bar icon → **Set OpenAI or OpenRouter key…**. The key is kept in the login keychain;
   `OPENAI_API_KEY` or `~/.config/openai/api_key` also work. An OpenRouter key (`sk-or-…`)
   reaches the same model at `openrouter.ai/api/alpha/decisions`
   (`openai/gpt-6-luna-decisions`), which takes a different request shape; the app picks the
   route from the key.
3. Menu → **Hide** → pick bubbles, or **Add your own…**. Ads are on by default.
4. Optional: **Set fal.ai key (for SAM)…** for tighter mask shapes. `FAL_KEY` or
   `~/.config/fal/api_key` also work. Turn it off under Finding regions.

Every judging pass is logged to `~/Library/Logs/SignalNoiseOS.log` (menu → Open log), with
cells, requests, seconds, what was hidden and any errors.

## How it works

- **Capture**: about three times a second, ScreenCaptureKit captures each display at one pixel per
  point, with no cursor. The app's own masks and the never-capture apps are left out.
- **Cells**: the screen is cut into a grid (8×5 by default; 6×4 or 12×8 in the menu). Each cell
  gets a 256-bit difference hash: plain pixel arithmetic, not a model.
- **Movement**: when a cell's hash changes, its mask fades out right away, so masks never trail
  behind scrolled content. Once the screen holds still for a frame, changed cells are resolved:
  from the verdict cache if the same content was judged before, otherwise by the model. Late
  answers are dropped if the cell has changed since. When an answer says hide, the mask fades in
  over 0.3 s.
- **Finding regions from pixels** (menu → Finding regions):
  - **Tiles**: one request per cell, a crop of the cell plus half a cell of context
    around it, the cell outlined in red, and one predicate per bubble ("does the outlined region
    show an ad?"). These are whole-image questions, the kind the model is documented on. Up to
    12 run at once.
  - **Grid** (default): one image of the whole screen with a labelled grid (A1…H5), and one choice
    question per cell, 20 per request. It relies on the model pointing at labelled cells, and on
    real pages it did that well (see First results).
- **Tighter shapes (SAM)**: when a new masked block appears, SAM 3 gets a crop of the block plus
  half a cell of margin, with the matching bubble as a noun phrase ("advertisement", "meme
  image"; your own words for custom bubbles). Boxes it finds (score ≥ 0.35, not tiny, not the
  whole crop) cross-fade in to replace the block's grid mask. If it finds nothing or fails, the
  grid mask stays. Decisions still decides *whether* to hide; SAM only decides the shape. It runs
  once per new masked block, never per frame. Text-only bubbles (rage bait, crypto) have no noun
  phrase and keep grid masks.
- **Masks**: adjacent masked cells merge into rectangles. Each one is a borderless panel above
  every app with a system blur and a label ("Hidden · Ads"). Only the masks take the mouse.
  Hovering for 0.3 s peeks through; a click reveals the mask until that content changes.
- **Never runs** while it's off, without a key or bubbles, while macOS reports secure text entry
  (a password field has focus), or while a never-capture app is in front (1Password, Bitwarden,
  Passwords, Keychain Access, System Settings). Those apps' windows are also left out of every
  capture.

## First results (2026-10-09, via OpenRouter)

Six real pages (Allrecipes, CNN, Daily Mail, old Reddit, Speedtest, Weather.com) were screenshotted
at 1440×900 in a headless browser and judged for Ads + Memes on an 8×5 grid:

| | per screen | requests | what it did |
|---|---|---|---|
| grid | 0.56–0.83 s | 2 | covered most of each real ad (leaderboards, side rails, video ad); a few false positives (a recipe photo, a heading) |
| tiles | 1.45–2.40 s | 40 | covered parts of ads and missed some (1 of 5 cells of the Speedtest banner) |

Nothing was masked on pages that had no loaded ads (empty CNN slot, Reddit login wall). Every call
answered. Each request is a few thousand input tokens at $0.10 per million, so roughly $0.0005 per
screen in grid mode. Six pages is a smoke test, not a benchmark: run `snos-eval` on your own
screenshots to tune the strictness.

## Privacy

Whatever is on screen goes to OpenAI as JPEG crops: tiles of your screen, or the whole screen in
grid mode. With SAM on, crops around masked areas also go to fal.ai. That includes email, chats and documents. The pause rules above are the only filter.
OpenAI offers zero data retention for eligible accounts only.

## Eval: does it find the right regions?

```sh
swift run snos-eval ~/Desktop/shots                         # both modes, Ads + Memes, 8x5
swift run snos-eval ~/Desktop/shots --mode tiles --grid 12x8 --bubbles ads,violence --custom "spiders"
swift run snos-eval ~/Desktop/shots --mode tiles --sam              # plus SAM shapes (needs FAL_KEY)
```

This runs the app's judging over a folder of screenshots and writes `report.html` and
`results.json` (to `<folder>/snos-report/` unless `--out` says otherwise). The report shows each
screenshot per mode with the cells that would be masked; hover a cell for its scores. It also
gives the median seconds per screen. With `--sam`, SAM's shapes are drawn as blue boxes. Use it to choose between tiles and grid, the grid size and
the strictness before trusting the live overlay. `SNOS_DECISIONS_URL` points both the app and the
eval at a stub server instead of OpenAI; `SNOS_SAM_URL` does the same for SAM.

## Develop

```sh
swift test      # MaskCore: request shape, answer parsing, grid and merging, hashing, image prep,
                # the tracker (drop on change, cache, late answers, reveal), both judge modes
                # against a stub, SAM box parsing and clipping
```

`Sources/MaskCore` is the pure, tested part. `Sources/SignalNoiseOS` is the app (AppKit,
ScreenCaptureKit). `Sources/snos-eval` is the eval command.

## Known gaps

- Without SAM, masks are grid-shaped, so they're blocky, and an ad that straddles cells masks
  every cell it touches. Finer grids give tighter masks but mean more requests.
- The verdict cache helps when the same content comes back in the same place (switching back to a
  window or tab). After a scroll, content rarely lines up with the grid the same way, so it's
  judged again.
- SAM only reshapes. It can't find things the grid missed, and a merged block that grows by a
  cell is reshaped again (another call).
- SAM shapes follow the grid's movement rules: they drop when the cells under them change, so a
  shape that spills past its block can briefly stay over content that scrolled away.
- Decisions has been run for real (via OpenRouter); SAM has only been run against a stub.
