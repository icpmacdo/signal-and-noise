// One display: hashes each captured frame's cells, asks the tracker what changed, sends unseen
// content to the model, and keeps mask panels for each merged block of masked cells. With
// tighter shapes on, a new block shows nothing until its shapes come back (a zoomed second look,
// or SAM when a fal.ai key is set), so a coarse cell never briefly covers tabs or headlines.
import AppKit
import MaskCore

@MainActor
final class DisplayWorker {
  let displayID: CGDirectDisplayID
  /// Global display coordinates (points, top-left origin), as ScreenCaptureKit reports them.
  let frame: CGRect
  let spec: GridSpec
  let tracker: Tracker
  private(set) var judging = false
  private var panels: [CellBlock: [MaskPanel]] = [:]
  /// Blocks waiting on their shapes.
  private var refining: Set<CellBlock> = []
  private var lastImage: CGImage?
  private var generation = 0
  var onJudged: ((JudgeResult, Int, [String]) -> Void)?
  /// Tighter shapes: the zoomed second look uses `fineClient`; SAM is used instead when set.
  /// `bubbles` maps a mask's reasons back to the bubbles that matched.
  var fineClient: DecisionsClient?
  var sam: SAMClient?
  var bubbles: [Bubble] = []

  init(displayID: CGDirectDisplayID, frame: CGRect, spec: GridSpec) {
    self.displayID = displayID
    self.frame = frame
    self.spec = spec
    tracker = Tracker(spec: spec)
  }

  func handle(_ image: CGImage, judge: Judge?) {
    let frameHashes = (0..<spec.count).map { RegionHash.of(image, rect: spec.rect($0, width: image.width, height: image.height)) }
    lastImage = image
    let step = tracker.observe(frameHashes, judging: judging)
    if step.masksChanged { render() }
    guard !step.toJudge.isEmpty, let judge else { return }
    judging = true
    let gen = generation
    Task { @MainActor in
      let result = await judge.judge(image, spec: spec, cells: step.toJudge)
      guard gen == generation else { return } // paused or settings changed meanwhile
      judging = false
      if tracker.record(result.verdicts, judgedHashes: step.judgedHashes) { render() }
      let hiddenCells = result.verdicts.filter(\.value.hide).keys.sorted().map { spec.label($0) }
      onJudged?(result, step.toJudge.count, hiddenCells)
      dump(image, result)
    }
  }

  /// The last pass on this display, for debugging: the frame as captured and every answer, in
  /// ~/Library/Logs/SignalNoiseOS/display-<id>.{jpg,json}. Overwritten each pass.
  private func dump(_ image: CGImage, _ result: JudgeResult) {
    let dir = Log.url.deletingPathExtension()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let url = Imaging.jpegDataURL(image, quality: 0.6), let data = Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))) {
      try? data.write(to: dir.appendingPathComponent("display-\(displayID).jpg"))
    }
    let cells = Dictionary(uniqueKeysWithValues: result.verdicts.map { (spec.label($0.key), ["hide": $0.value.hide, "scores": $0.value.scores] as [String: Any]) })
    let json: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "grid": "\(spec.cols)x\(spec.rows)",
                               "frame": [frame.minX, frame.minY, frame.width, frame.height], "image": [image.width, image.height],
                               "seconds": result.seconds, "errors": result.errors, "cells": cells,
                               "masked": tracker.masked.keys.sorted().map { spec.label($0) }]
    if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: dir.appendingPathComponent("display-\(displayID).json"))
    }
  }

  /// Drop all masks and forget the screen; with keepCache false, also forget past verdicts.
  func reset(keepCache: Bool) {
    generation += 1
    judging = false
    tracker.reset(keepCache: keepCache)
    for p in panels.values.joined() { p.fadeOutAndClose() }
    panels.removeAll()
    refining.removeAll()
  }

  private func currentBlocks() -> Set<CellBlock> { Set(Merge.blocks(Set(tracker.masked.keys), spec: spec)) }

  private func render() {
    let blocks = currentBlocks()
    for (block, ps) in panels where !blocks.contains(block) {
      ps.forEach { $0.fadeOutAndClose() }
      panels.removeValue(forKey: block)
    }
    refining.formIntersection(blocks)
    for block in blocks {
      let label = labelFor(block)
      if let existing = panels[block] { existing.forEach { $0.setLabel(label) }; continue }
      if refining.contains(block) { continue }
      if fineClient != nil || sam != nil, let image = lastImage {
        refining.insert(block)
        refine(block, image: image)
      } else {
        panels[block] = [makePanel(spec.rect(block, width: Int(frame.width), height: Int(frame.height)), block: block, label: label)]
      }
    }
  }

  private func makePanel(_ local: CGRect, block: CellBlock, label: String) -> MaskPanel {
    let cells = block.cells(spec)
    let panel = MaskPanel(frame: screenRect(local), label: label) { [weak self] in
      guard let self else { return }
      self.tracker.reveal(cells)
      Log.write("revealed \(cells.map { self.spec.label($0) }.joined(separator: ",")) on display \(self.displayID)")
      self.render()
    }
    panel.fadeIn()
    return panel
  }

  /// Find the shape of what's in a new block. Shapes found: mask those. Nothing found: the
  /// zoomed look overrules the coarse one and nothing is masked. Every call failed: mask the
  /// whole block, since the coarse pass did say hide.
  private func refine(_ block: CellBlock, image: CGImage) {
    let reasons = Set(block.cells(spec).flatMap { tracker.masked[$0]?.reasons ?? [] })
    let matched = bubbles.filter { reasons.contains($0.label) }
    let prompts = matched.compactMap(\.segment)
    let gen = generation
    let first = spec.label(block.cells(spec)[0])
    Task { @MainActor in
      var rects: [CGRect] = [], errors: [String] = [], how = ""
      let t0 = Date()
      if let sam, !prompts.isEmpty {
        let r = await Refine.block(block, image: image, spec: spec, prompts: prompts, client: sam)
        (rects, errors, how) = (r.rects, r.errors, "SAM")
      } else if let fineClient {
        let r = await FineRefine.block(block, image: image, spec: spec, matched: matched, client: fineClient)
        (rects, errors, how) = (r.rects, r.errors, "zoom")
      }
      Log.write(String(format: "display %u %@ %@…: %d shapes, %.2f s%@", displayID, how, first, rects.count, Date().timeIntervalSince(t0),
                       errors.isEmpty ? "" : " errors: \(errors.joined(separator: " | ").prefix(300))"))
      guard gen == generation, refining.remove(block) != nil, currentBlocks().contains(block) else { return }
      let label = labelFor(block)
      if !rects.isEmpty {
        // Captured pixels are display points, so image rects are local screen rects.
        panels[block] = rects.map { makePanel($0, block: block, label: label) }
      } else if !errors.isEmpty {
        panels[block] = [makePanel(spec.rect(block, width: Int(frame.width), height: Int(frame.height)), block: block, label: label)]
      } else {
        panels[block] = [] // refined away; remembered so it isn't asked again
      }
    }
  }

  private func labelFor(_ block: CellBlock) -> String {
    var reasons: [String] = []
    for i in block.cells(spec) { for r in tracker.masked[i]?.reasons ?? [] where !reasons.contains(r) { reasons.append(r) } }
    return "Hidden · \(reasons.isEmpty ? "muted" : reasons.joined(separator: ", "))"
  }

  /// A rect in this display's points (top-left origin) in AppKit screen coordinates
  /// (bottom-left origin of the main display).
  private func screenRect(_ local: CGRect) -> NSRect {
    let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
    return NSRect(x: frame.minX + local.minX, y: mainHeight - (frame.minY + local.maxY), width: local.width, height: local.height)
      .insetBy(dx: 1, dy: 1)
  }
}
