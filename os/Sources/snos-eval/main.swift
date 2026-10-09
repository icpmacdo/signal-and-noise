// Run the app's judging over a folder of screenshots and write an HTML report: which cells each
// way of finding regions would mask, with scores and timings. This is how to tell whether the
// model finds the right regions from pixels before trusting the live overlay.
//
//   swift run snos-eval ~/Desktop/shots                       # both modes, ads + memes
//   swift run snos-eval ~/Desktop/shots --mode tiles --grid 12x8 --bubbles ads,violence --custom "spiders"
//   swift run snos-eval ~/Desktop/shots --mode tiles --sam     # also reshape masks with SAM 3 on fal.ai
//   swift run snos-eval ~/Desktop/shots --mode grid --refine fine   # zoomed second pass (the app's default)
//
// With <folder>/labels.json ({"file.png": [[x, y, w, h], …]}, image pixels, [] for no ads) it
// scores the masks: recall = share of labelled area masked, precision = share of masked area
// that is labelled. Coarse cells and refined shapes are scored separately.
//
// Keys: OPENAI_API_KEY or ~/.config/openai/api_key (an OpenRouter sk-or- key works too); for --sam, FAL_KEY or ~/.config/fal/api_key.
// SNOS_DECISIONS_URL / SNOS_SAM_URL point it at stubs instead.
import Foundation
import MaskCore

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data("snos-eval: \(msg)\n".utf8))
  exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> [String] {
  var out: [String] = []
  while let i = args.firstIndex(of: name), i + 1 < args.count {
    out.append(args[i + 1])
    args.removeSubrange(i...(i + 1))
  }
  return out
}
var modes = Mode.allCases
if let m = option("--mode").last, m != "both" {
  guard let mode = Mode(rawValue: m) else { fail("unknown mode \(m); use tiles, grid or both") }
  modes = [mode]
}
var spec = GridSpec(cols: 8, rows: 5)
if let g = option("--grid").last {
  guard let parsed = GridSpec(g) else { fail("bad --grid \(g), use e.g. 8x5") }
  spec = parsed
}
let picked = option("--bubbles").last.map { $0.split(separator: ",").map(String.init) } ?? ["ads", "memes"]
let customs = option("--custom")
let threshold = option("--threshold").last.flatMap(Double.init) ?? 0.6
let outOpt = option("--out").last
let useSAM = args.contains("--sam")
args.removeAll { $0 == "--sam" }
let refineMode = option("--refine").last ?? (useSAM ? "sam" : "fine") // none | fine | sam
let sub = option("--sub").last.flatMap(Int.init) ?? 3
let margin = option("--margin").last.flatMap(Double.init) ?? 0.5
let fineThreshold = option("--fine-threshold").last.flatMap(Double.init) ?? 0.5
let labelsPath = option("--labels").last
let gridAsk = option("--grid-ask").last.flatMap(GridAsk.init(rawValue:)) ?? .choice
guard let folder = args.first else {
  fail("usage: snos-eval <folder of screenshots> [--mode tiles|grid|both] [--grid 8x5] [--bubbles ads,memes] [--custom text]… [--threshold 0.6] [--out dir]")
}
for p in picked where !Bubbles.common.contains(where: { $0.id == p }) {
  fail("unknown bubble \(p); known: \(Bubbles.common.map(\.id).joined(separator: ","))")
}
let bubbles = Bubbles.active(picked: picked, customs: customs)

let env = ProcessInfo.processInfo.environment
let url = env["SNOS_DECISIONS_URL"].flatMap(URL.init(string:))
let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/openai/api_key")
let key = env["OPENAI_API_KEY"] ?? (try? String(contentsOf: keyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
if key.isEmpty && url == nil { fail("no key: set OPENAI_API_KEY (an OpenAI or OpenRouter key) or write it to ~/.config/openai/api_key") }
let client = DecisionsClient(key: key, url: url, timeout: 30)
var sam: SAMClient?
if useSAM {
  let samURL = env["SNOS_SAM_URL"].flatMap(URL.init(string:)) ?? SAMClient.defaultURL
  let falFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/fal/api_key")
  let falKey = env["FAL_KEY"] ?? (try? String(contentsOf: falFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  if falKey.isEmpty && samURL == SAMClient.defaultURL { fail("--sam needs FAL_KEY or ~/.config/fal/api_key") }
  sam = SAMClient(key: falKey, url: samURL)
}

let dir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
  .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }
if files.isEmpty { fail("no .png/.jpg files in \(dir.path)") }
let out = URL(fileURLWithPath: ((outOpt ?? dir.appendingPathComponent("snos-report").path) as NSString).expandingTildeInPath)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

struct Row: Encodable {
  let file: String
  let mode: String
  let seconds: Double
  let requests: Int
  let errors: [String]
  let cells: [String: Verdict]
  /// Refined shapes per masked block (first cell's label), image pixels.
  let shapes: [String: [[Double]]]
  let refineSeconds: Double
  let refineRequests: Int
}

let labelsURL = labelsPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? dir.appendingPathComponent("labels.json")
let labels: [String: [[Double]]] = (try? Data(contentsOf: labelsURL)).flatMap { try? JSONDecoder().decode([String: [[Double]]].self, from: $0) } ?? [:]
if !labels.isEmpty { print("scoring against \(labelsURL.lastPathComponent) (\(labels.count) files)") }
/// mode -> [coarse, refined] -> (masked, truth, overlap) totals
var totals: [String: [[Int]]] = [:]
func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.0f%%", Double(a) / Double(b) * 100) }

func html(_ s: String) -> String {
  s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
}

var rows: [Row] = []
var sections: [String] = []
for file in files {
  guard let image = Imaging.load(file) else { print("skip \(file.lastPathComponent): unreadable"); continue }
  var columns: [String] = []
  for mode in modes {
    let judge = Judge(client: client, bubbles: bubbles, threshold: threshold, mode: mode, gridAsk: gridAsk)
    let r = await judge.judge(image, spec: spec, cells: Array(0..<spec.count))
    let hidden = r.verdicts.filter { $0.value.hide }
    var shapes: [String: [CGRect]] = [:]
    var refineSeconds = 0.0, refineRequests = 0
    let blocks = Merge.blocks(Set(hidden.keys), spec: spec)
    if refineMode != "none" {
      let t0 = Date()
      for block in blocks {
        let reasons = Set(block.cells(spec).flatMap { hidden[$0]?.reasons ?? [] })
        let matched = bubbles.filter { reasons.contains($0.label) }
        var rects: [CGRect] = [], errors: [String] = []
        if refineMode == "sam", let sam {
          let res = await Refine.block(block, image: image, spec: spec, prompts: matched.compactMap(\.segment), client: sam)
          rects = res.rects; errors = res.errors; refineRequests += matched.count
        } else {
          let res = await FineRefine.block(block, image: image, spec: spec, matched: matched, client: client,
                                           threshold: fineThreshold, sub: sub, margin: CGFloat(margin))
          rects = res.rects; errors = res.errors; refineRequests += res.requests
        }
        for e in errors.prefix(1) { print("  refine error: \(e)") }
        shapes[spec.label(block.cells(spec)[0])] = rects // empty: refined away (nothing found)
      }
      refineSeconds = Date().timeIntervalSince(t0)
    }
    print(String(format: "%@ %@ via %@: %d/%d answered, %d masked, %d requests, %.2f s%@", file.lastPathComponent, mode.rawValue, client.route.rawValue,
                 r.verdicts.count, spec.count, hidden.count, r.requests, r.seconds, r.errors.isEmpty ? "" : ", \(r.errors.count) errors"))
    for e in r.errors.prefix(2) { print("  error: \(e)") }
    if refineMode != "none" { print(String(format: "  refine (%@): %d blocks, %d requests, %.2f s", refineMode, blocks.count, refineRequests, refineSeconds)) }
    var scoreText = ""
    if let truth = labels[file.lastPathComponent] {
      let truthRects = truth.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
      let coarse = blocks.map { spec.rect($0, width: image.width, height: image.height) }
      // A block the refine pass emptied is unmasked; with refining off the coarse cells stand.
      let refined = refineMode == "none" ? coarse : blocks.flatMap { shapes[spec.label($0.cells(spec)[0])] ?? [] }
      var t = totals[mode.rawValue] ?? [[0, 0, 0], [0, 0, 0]]
      var parts: [String] = []
      for (k, (name, rects)) in [("cells", coarse), ("refined", refined)].enumerated() {
        let c = Coverage.score(masked: rects, truth: truthRects, width: image.width, height: image.height)
        t[k][0] += c.maskedArea; t[k][1] += c.truthArea; t[k][2] += c.overlap
        parts.append("\(name): recall \(pct(c.overlap, c.truthArea)), precision \(pct(c.overlap, c.maskedArea))")
      }
      totals[mode.rawValue] = t
      scoreText = parts.joined(separator: " · ")
      print("  " + scoreText)
    }
    rows.append(Row(file: file.lastPathComponent, mode: mode.rawValue, seconds: r.seconds, requests: r.requests, errors: r.errors,
                    cells: Dictionary(uniqueKeysWithValues: r.verdicts.map { (spec.label($0.key), $0.value) }),
                    shapes: shapes.mapValues { $0.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } },
                    refineSeconds: refineSeconds, refineRequests: refineRequests))
    var overlay = ""
    for i in 0..<spec.count {
      let rect = spec.rect(i, width: image.width, height: image.height)
      let v = r.verdicts[i]
      let scores = bubbles.map { b in String(format: "%@ %.0f%%", b.label, (v?.scores[b.id] ?? 0) * 100) }.joined(separator: ", ")
      let tip = "\(spec.label(i)): \(v == nil ? "no answer" : scores)"
      let cls = v == nil ? "cell none" : v!.hide ? "cell hit" : "cell"
      overlay += String(format: "<div class=\"%@\" title=\"%@\" style=\"left:%.3f%%;top:%.3f%%;width:%.3f%%;height:%.3f%%\">%@</div>",
                        cls, html(tip), rect.minX / CGFloat(image.width) * 100, rect.minY / CGFloat(image.height) * 100,
                        rect.width / CGFloat(image.width) * 100, rect.height / CGFloat(image.height) * 100,
                        v?.hide == true ? "<span>\(html(v!.reasons.joined(separator: ", ")))</span>" : "")
    }
    for t in labels[file.lastPathComponent] ?? [] {
      overlay += String(format: "<div class=\"truth\" style=\"left:%.3f%%;top:%.3f%%;width:%.3f%%;height:%.3f%%\"></div>",
                        t[0] / Double(image.width) * 100, t[1] / Double(image.height) * 100, t[2] / Double(image.width) * 100, t[3] / Double(image.height) * 100)
    }
    for rect in shapes.values.joined() {
      overlay += String(format: "<div class=\"shape\" style=\"left:%.3f%%;top:%.3f%%;width:%.3f%%;height:%.3f%%\"></div>",
                        rect.minX / CGFloat(image.width) * 100, rect.minY / CGFloat(image.height) * 100,
                        rect.width / CGFloat(image.width) * 100, rect.height / CGFloat(image.height) * 100)
    }
    columns.append("""
      <figure><figcaption><b>\(mode.rawValue)</b> · \(hidden.count) masked · \(r.requests) requests · \(String(format: "%.2f", r.seconds)) s\(refineMode == "none" ? "" : String(format: " · %@ %d shapes, %d requests, %.2f s", refineMode, shapes.values.reduce(0) { $0 + $1.count }, refineRequests, refineSeconds))\(scoreText.isEmpty ? "" : "<br>\(scoreText)")\(r.errors.isEmpty ? "" : " · <em>\(r.errors.count) errors</em>")</figcaption>
      <div class="shot"><img src="\(html(file.absoluteString))">\(overlay)</div></figure>
      """)
  }
  sections.append("<section><h2>\(html(file.lastPathComponent))</h2><div class=\"cols\">\(columns.joined())</div></section>")
}

let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(rows).write(to: out.appendingPathComponent("results.json"))
let summary = modes.map { m -> String in
  let rs = rows.filter { $0.mode == m.rawValue }
  let secs = rs.map(\.seconds).sorted()
  let median = secs.isEmpty ? 0 : secs[secs.count / 2]
  return String(format: "<li><b>%@</b>: median %.2f s per screen, %d requests total, %d errors</li>", m.rawValue, median,
                rs.reduce(0) { $0 + $1.requests }, rs.reduce(0) { $0 + $1.errors.count })
}.joined()
let page = """
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mask Eval</title><style>
:root{--bg:#fff;--fg:#14171a;--muted:#5b6670;--line:#d5dbe0;--hit:rgba(220,38,38,.55)}
@media (prefers-color-scheme:dark){:root{--bg:#0f1214;--fg:#e7e9ea;--muted:#8b98a5;--line:#2f3336}}
body{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,system-ui,sans-serif}
main{max-width:1500px;margin:0 auto}h1{font-size:22px;margin:0 0 4px}p,li{color:var(--muted)}
section{margin:28px 0;border-top:1px solid var(--line);padding-top:12px}h2{font-size:15px;margin:0 0 8px}
.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,520px),1fr));gap:16px}
figure{margin:0}figcaption{font-size:13px;color:var(--muted);margin-bottom:6px}
.shot{position:relative;line-height:0}.shot img{width:100%;height:auto;border-radius:6px}
.cell{position:absolute;box-sizing:border-box;border:1px solid rgba(127,127,127,.25)}
.cell.none{background:repeating-linear-gradient(45deg,transparent 0 6px,rgba(127,127,127,.25) 6px 8px)}
.cell.hit{background:var(--hit);border:2px solid rgb(220,38,38);backdrop-filter:blur(6px)}
.shape{position:absolute;box-sizing:border-box;border:3px solid rgb(37,99,235);background:rgba(37,99,235,.18)}
.truth{position:absolute;box-sizing:border-box;border:3px dashed rgb(22,163,74)}
.cell span{position:absolute;left:4px;top:4px;font:600 11px/1.2 -apple-system,sans-serif;color:#fff;background:rgb(220,38,38);padding:2px 5px;border-radius:4px}
</style></head><body><main>
<h1>Mask eval</h1>
<p>Grid \(spec.cols)×\(spec.rows) · bubbles: \(html(bubbles.map(\.label).joined(separator: ", "))) · mask at \(Int(threshold * 100))% · \(files.count) screenshots. Red cells would be masked; hover any cell for its scores; striped cells got no answer.\(refineMode == "none" ? "" : " Blue boxes are the refined shapes, which replace the red cells they overlap.")</p>
<ul>\(summary)</ul>
\(sections.joined(separator: "\n"))
</main></body></html>
"""
try page.write(to: out.appendingPathComponent("report.html"), atomically: true, encoding: String.Encoding.utf8)
for (mode, t) in totals.sorted(by: { $0.key < $1.key }) {
  print("\(mode) overall: cells recall \(pct(t[0][2], t[0][1])), precision \(pct(t[0][2], t[0][0])) · refined recall \(pct(t[1][2], t[1][1])), precision \(pct(t[1][2], t[1][0]))")
}
print("report: \(out.appendingPathComponent("report.html").path)")
