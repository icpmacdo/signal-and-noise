# Signal & Noise for macOS (experimental)

The extension's idea applied to the whole screen. A menu-bar app watches every display and blurs
the parts that match your bubbles (ads, memes, graphic violence, anything you type). It works from
pixels only, so it runs in any app. Hover over a mask to peek through it; click to show it.

Judging uses OpenAI's [Decisions API](https://developers.openai.com/api/docs/guides/decisions)
(`gpt-6-luna`, `POST /v1/decisions`). It's billed for input only ($0.10 per million tokens), so many
questions about one picture cost about the same as one. Optionally, masks are reshaped with Meta's
SAM 3, hosted on [fal.ai](https://fal.ai/models/fal-ai/sam-3/image) ($0.005 per call). With a
TypeSafe key instead, every question goes to TypeSafe's Jev 1.14 (`jev-1.14.0`,
`POST api.typesafe.ai/v1/systemone`; images are a TypeSafe preview). No model runs on this Mac.

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
   route from the key. Or **Set TypeSafe key (Jev)…** (`TYPESAFE_API_KEY` or
   `~/.config/typesafe/api_key` also work): used when no OpenAI or OpenRouter key is set.
3. Menu → **Hide** → pick bubbles, or **Add your own…**. Ads are on by default.
4. Optional: **Set fal.ai key (for SAM)…** for tighter mask shapes. `FAL_KEY` or
   `~/.config/fal/api_key` also work. Turn it off under Finding regions.

Every judging pass is logged to `~/Library/Logs/SignalNoiseOS.log` (menu → Open log), with
cells, requests, seconds, what was hidden and any errors; the route and model are logged at
start, and each refined block's shapes with their positions.

Menu → **Show usage widget** opens a small floating panel with what the models cost while the app
runs: requests, tokens and dollars per model for this session, the last minute (with the hourly
rate it implies) and today (kept across restarts). The menu also shows today's total. Costs are
what the response says where it says (OpenRouter returns each call's cost); otherwise tokens times
list prices (luna $0.10, Jev $0.042 per million input tokens; SAM $0.005 a call), marked ≈.

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
- **Tighter shapes (zoomed second look, default)**: the coarse 8×5 grid is good at noticing that
  an ad is somewhere in a cell and bad at its edges (on a 6K display a cell is 376×338 points, so
  cell masks covered browser tabs and headlines while the rest of the ad showed). So a new masked
  block plus half a cell of margin is cropped at full resolution, a fine grid (3×3 per coarse
  cell) is drawn on it, and the model answers "does this cell show any part of an ad?" for each
  subcell. The mask is those subcells. Nothing is masked until that answer is back (about 0.6 s
  more), so a coarse cell never flashes over the wrong thing. If the zoomed look finds nothing,
  nothing is masked; if its calls fail, the whole block is.
- **Tighter shapes (SAM, with a fal.ai key)**: instead of the zoomed look, SAM 3 gets a crop of the block plus
  half a cell of margin, with the matching bubble as a noun phrase ("advertisement", "meme
  image"; your own words for custom bubbles). Boxes it finds (score ≥ 0.35, not tiny, not the
  whole crop) cross-fade in to replace the block's grid mask. If it finds nothing or fails, the
  grid mask stays. Decisions still decides *whether* to hide; SAM only decides the shape. It runs
  once per new masked block, never per frame. Text-only bubbles (rage bait, crypto) have no noun
  phrase and keep grid masks.
- **From the Vision Jev box thread (2026-10-16)** (menu → Finding regions; see "Jev boxes on
  real pages" below for the numbers):
  - **Shapes from Jev boxes** (default with an OpenRouter or TypeSafe key): TypeSafe's Jev 1.14
    answers "where is the ad?" with one box. Each new block is searched in a loop instead of the
    zoomed look: crop it plus half a cell at full resolution, ask "is there an ad?" (noul) and
    "where?" (box) in one request, paint the box out and ask again until the answer is no (4 boxes
    at most). With checking on, a box that fails its check splits the crop in half and each half
    is searched (two levels at most, 12 requests per block at most). On OpenRouter this uses
    `typesafe/jev-1.14` with the same key; with a TypeSafe key it's `jev-1.14.0` direct. With an
    OpenAI key there are no box questions and the zoomed look is used.
  - **Check each mask** (off): before a shape shows, a crop around it with the shape outlined in red is
    asked "is what's inside mostly an ad?" two ways in one request (a yes/no and a choice), and the
    shape is dropped only if both say no. In the thread's beetle tests checking threw out bad boxes
    but also one real one, hence the two wordings. A failed check keeps the shape.
  - **Ask again with found ads painted out** (off): once per pass, every flagged or masked cell is
    painted with the colour around it and the cells that came back clean are asked again. This
    goes after what's left in the tuning below: ads the coarse pass never flagged.
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

### Tuning the zoomed look (2026-10-09)

Four WSJ/NYT screenshots from a 6K display with the ads labelled by hand, plus two pages with no
ads (`snos-eval` with `labels.json`). Recall is the share of ad area masked; precision is the
share of masked area that is ad. The runs are noisy: the same settings vary by ±10 points.

| | recall | precision |
|---|---|---|
| coarse cells only (threshold 0.6) | 46% | 28% |
| + zoomed look, coarse threshold 0.6 | 55% | 61% |
| + zoomed look, coarse threshold 0.5 (default) | 65–67% | 57–60% |
| coarse threshold 0.4 | 58–72% | 41–69% |
| subcells 4×4 instead of 3×3 | 33% | 30% |
| coarse yes/no questions instead of a choice | 50–69% | 42–51% |
| 14×8 coarse grid instead of 8×5 | worse; scattered cells | |

What's left is mostly the coarse pass missing an ad entirely in some runs; the zoomed look can't
mask what was never flagged.

### Jev boxes on real pages (2026-10-18)

Eight pages screenshotted at 1440×900 in headless Chrome (Allrecipes, Weather.com, Daily Mail,
Speedtest, Fox News, Yahoo with 15 loaded ads between them; AccuWeather and Wikipedia with none),
the ads labelled from each page's ad iframes and checked by eye, empty ad slots left out. Every
question went to Jev 1.14 direct (TypeSafe key), Ads only, 8×5 grid, coarse threshold 0.5, three
runs each. "Found" is labelled ads with at least half their area masked.

| shapes | recall | precision | ads found (of 15) | requests per screen |
|---|---|---|---|---|
| zoomed look (the old default) | 52% (43–60) | 69% (64–71) | 8.5 (7–10) | 8 |
| **Jev boxes (now the default)** | **88% (86–90)** | **87% (84–90)** | **13.7 (13–14)** | **9** |
| Jev boxes + check each mask | 87% | 85% | 14.0 | 14 |
| Jev boxes + check + ask again | 86% | 83% | 14.0 (13–15) | 18 |
| zoomed look + check each mask | 42% | 78% | 6.3 | 22 |
| zoomed look + ask again | 52% | 68% | 8.3 | 11 |
| zoomed look + ask again + check | 48% | 79% | 8.3 | 25 |

On Jev the coarse grid alone found 13–14 of 15 ads (about 78% recall, 57% precision); the zoomed
look then lost about 5 of them, because Jev's answers about fine-grid cells land on logos,
buttons and headlines. Boxes keep them, and since the search crop has a margin, boxes also cover
parts of ads the coarse cells missed. Checking each mask raised precision on the zoomed look's
scattered shapes but dropped real ads too (as in the beetle tests); on boxes it changed nothing
for 50% more requests. Asking again found an extra ad now and then for twice the coarse requests.
Box shapes spend about 0.3–0.4 s per block. Not measured: Jev boxes behind gpt-6-luna's coarse pass
(an OpenRouter key), and the earlier WSJ/NYT set, which isn't on this Mac any more.

A bigger set followed the same day: 23 screenshots, 28 ads (`eval-out/sets/ads-v2/`, git-ignored,
with LABELS.md): 18 pages with ads including 5 scrolled about 1200 px and 2 at 3008×1692 (a 6K
display at one pixel per point), and 5 without. Same settings, Jev direct, three runs each:

| shapes | recall | precision | ads found (of 28) | requests per screen |
|---|---|---|---|---|
| zoomed look | 41% (40–42) | 59% (57–61) | 11.3 (11–12) | 5.2 |
| Jev boxes | 63% (62–65) | 69% (67–73) | 17.0 (17) | 5.5 |
| Jev boxes + check each mask | 62% (60–63) | 71% (70–73) | 16.3 (16–17) | 7.8 |
| Jev boxes + ask again | 69% (65–75) | 72% (69–76) | 19.3 (19–20) | 7.4 |

The first set flattered everything; on this one boxes still beat the zoomed look on every subset
but the two 6K shots (a tie on 3 ads), and masked nothing on the 5 pages without ads. Most of
what's left is the coarse pass: grid cells reach only 17 of the 28 ads, and boxes can't find what
they're never pointed at. Asking again with finds painted out recovers about 2 of those for a
third more requests; it can't help a page where nothing at all was flagged (CBS News's sticky
footer ads are missed in every run).

## Privacy

Whatever is on screen goes to OpenAI (or OpenRouter, or TypeSafe, by key) as JPEG crops: tiles of
your screen, or the whole screen in grid mode. With SAM on, crops around masked areas also go to fal.ai. That includes email, chats and documents. The pause rules above are the only filter.
OpenAI offers zero data retention for eligible accounts only.

## Eval: does it find the right regions?

```sh
swift run snos-eval ~/Desktop/shots                         # both modes, Ads + Memes, 8x5
swift run snos-eval ~/Desktop/shots --mode tiles --grid 12x8 --bubbles ads,violence --custom "spiders"
swift run snos-eval ~/Desktop/shots --mode grid --threshold 0.5      # zoomed second look (default)
swift run snos-eval ~/Desktop/shots --mode grid --refine sam         # SAM shapes instead (needs FAL_KEY)
swift run snos-eval ~/Desktop/shots --mode grid --reask --verify     # ask again painted out; check each shape
swift run snos-eval ~/Desktop/shots --mode grid --refine box         # Jev box shapes (OpenRouter or TypeSafe key)
swift run snos-eval ~/Desktop/shots --mode grid --refine box --route typesafe   # every question to Jev direct
```

The eval takes `OPENAI_API_KEY` or `~/.config/openai/api_key` (OpenAI or OpenRouter), or
`TYPESAFE_API_KEY` or `~/.config/typesafe/api_key` for Jev direct, which it uses when it finds no
other key.

This runs the app's judging over a folder of screenshots and writes `report.html` and
`results.json` (to `<folder>/snos-report/` unless `--out` says otherwise). The report shows each
screenshot per mode with the cells that would be masked; hover a cell for its scores. It also
gives the median seconds per screen. Refined shapes are drawn as blue boxes. With a `labels.json` in
the folder (`{"shot.png": [[x, y, w, h], …]}` in image pixels, `[]` for a page with no ads) it
scores recall and precision for coarse cells and refined shapes, plus how many labelled ads are found (at least half their area masked), and draws the labels in green. Cells found only on the second look are dashed; shapes the check dropped are grey and hatched. Use it to choose between tiles and grid, the grid size and
the strictness before trusting the live overlay. `SNOS_DECISIONS_URL` points both the app and the
eval at a stub server instead of OpenAI; `SNOS_SAM_URL` does the same for SAM.

## Develop

```sh
swift test      # MaskCore: request shape, answer parsing, grid and merging, hashing, image prep,
                # the tracker (drop on change, cache, late answers, reveal), both judge modes
                # against a stub, SAM box parsing and clipping, box answers, painting out, the
                # check, asking again, the box search (found, rejected and split, budget),
                # the TypeSafe route (assets, images header, refitting to Jev's size limits)
```

`Sources/MaskCore` is the pure, tested part. `Sources/SignalNoiseOS` is the app (AppKit,
ScreenCaptureKit). `Sources/snos-eval` is the eval command.

## Known gaps

- With an OpenAI key (no box questions) and without SAM, masks are grid-shaped, so they're blocky, and an ad that straddles cells masks
  every cell it touches. Finer grids give tighter masks but mean more requests.
- The verdict cache helps when the same content comes back in the same place (switching back to a
  window or tab). After a scroll, content rarely lines up with the grid the same way, so it's
  judged again.
- SAM only reshapes. It can't find things the grid missed, and a merged block that grows by a
  cell is reshaped again (another call).
- SAM shapes follow the grid's movement rules: they drop when the cells under them change, so a
  shape that spills past its block can briefly stay over content that scrolled away.
- Decisions has been run for real (via OpenRouter); SAM has only been run against a stub.
- Jev boxes, checking and asking again have been run for real only on the TypeSafe route, on 8
  pages. The OpenRouter route for them has only been run against a stub.
- Box shapes spill past their ads a little (a box sometimes takes in the search bar above a
  leaderboard), and one box per question means a block holding two ads needs two requests.
- When both an OpenAI/OpenRouter key and a TypeSafe key are set, the OpenAI/OpenRouter key wins.
