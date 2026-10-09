// One display: hashes each captured frame's cells, asks the tracker what changed, sends unseen
// content to the model, and keeps mask panels for each merged block of masked cells: the block
// itself at first, then SAM's tighter shapes if they come back.
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
  private var refined: Set<CellBlock> = []
  private var lastImage: CGImage?
  private var generation = 0
  var onJudged: ((JudgeResult, Int, [String]) -> Void)?
  /// Set for tighter shapes; `bubbles` maps a mask's reasons back to SAM noun phrases.
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
    refined.removeAll()
  }

  private func render() {
    let blocks = Set(Merge.blocks(Set(tracker.masked.keys), spec: spec))
    for (block, ps) in panels where !blocks.contains(block) {
      ps.forEach { $0.fadeOutAndClose() }
      panels.removeValue(forKey: block)
      refined.remove(block)
    }
    for block in blocks {
      let label = labelFor(block)
      if let existing = panels[block] { existing.forEach { $0.setLabel(label) }; continue }
      let rect = spec.rect(block, width: Int(frame.width), height: Int(frame.height))
      panels[block] = [makePanel(rect, block: block, label: label)]
      refine(block)
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

  /// Ask SAM for the shape of what's in a new block; swap the grid mask for those shapes if any
  /// come back while the block is still masked.
  private func refine(_ block: CellBlock) {
    guard let sam, let image = lastImage else { return }
    let reasons = Set(block.cells(spec).flatMap { tracker.masked[$0]?.reasons ?? [] })
    let prompts = bubbles.filter { reasons.contains($0.label) }.compactMap(\.segment)
    guard !prompts.isEmpty else { return }
    let gen = generation
    Task { @MainActor in
      let r = await Refine.block(block, image: image, spec: spec, prompts: prompts, client: sam)
      Log.write("display \(displayID) SAM \(prompts) on \(spec.label(block.cells(spec)[0]))…: \(r.rects.count) shapes\(r.errors.isEmpty ? "" : " errors: \(r.errors.joined(separator: " | ").prefix(300))")")
      guard gen == generation, let old = panels[block], !refined.contains(block), !r.rects.isEmpty else { return }
      refined.insert(block)
      let label = labelFor(block)
      // Captured pixels are display points, so image rects are local screen rects.
      panels[block] = r.rects.map { makePanel($0, block: block, label: label) }
      old.forEach { $0.fadeOutAndClose(0.3) }
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
