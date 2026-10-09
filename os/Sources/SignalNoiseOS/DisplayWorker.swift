// One display: hashes each captured frame's cells, asks the tracker what changed, sends unseen
// content to the model, and keeps one mask panel per merged block of masked cells.
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
  private var panels: [CellBlock: MaskPanel] = [:]
  private var generation = 0
  var onJudged: ((JudgeResult, Int) -> Void)?

  init(displayID: CGDirectDisplayID, frame: CGRect, spec: GridSpec) {
    self.displayID = displayID
    self.frame = frame
    self.spec = spec
    tracker = Tracker(spec: spec)
  }

  func handle(_ image: CGImage, judge: Judge?) {
    let frameHashes = (0..<spec.count).map { RegionHash.of(image, rect: spec.rect($0, width: image.width, height: image.height)) }
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
      onJudged?(result, step.toJudge.count)
    }
  }

  /// Drop all masks and forget the screen; with keepCache false, also forget past verdicts.
  func reset(keepCache: Bool) {
    generation += 1
    judging = false
    tracker.reset(keepCache: keepCache)
    for p in panels.values { p.fadeOutAndClose() }
    panels.removeAll()
  }

  private func render() {
    let blocks = Set(Merge.blocks(Set(tracker.masked.keys), spec: spec))
    for (block, panel) in panels where !blocks.contains(block) {
      panel.fadeOutAndClose()
      panels.removeValue(forKey: block)
    }
    for block in blocks {
      let label = labelFor(block)
      if let existing = panels[block] { existing.setLabel(label); continue }
      let cells = block.cells(spec)
      let panel = MaskPanel(frame: screenRect(block), label: label) { [weak self] in
        guard let self else { return }
        self.tracker.reveal(cells)
        Log.write("revealed \(cells.map { self.spec.label($0) }.joined(separator: ",")) on display \(self.displayID)")
        self.render()
      }
      panels[block] = panel
      panel.fadeIn()
    }
  }

  private func labelFor(_ block: CellBlock) -> String {
    var reasons: [String] = []
    for i in block.cells(spec) { for r in tracker.masked[i]?.reasons ?? [] where !reasons.contains(r) { reasons.append(r) } }
    return "Hidden · \(reasons.isEmpty ? "muted" : reasons.joined(separator: ", "))"
  }

  /// A block in AppKit screen coordinates (bottom-left origin of the main display).
  private func screenRect(_ block: CellBlock) -> NSRect {
    // Cells are laid out in display points: the capture is one pixel per point.
    let local = spec.rect(block, width: Int(frame.width), height: Int(frame.height))
    let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
    return NSRect(x: frame.minX + local.minX, y: mainHeight - (frame.minY + local.maxY), width: local.width, height: local.height)
      .insetBy(dx: 1, dy: 1)
  }
}
