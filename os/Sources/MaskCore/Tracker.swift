// What to mask on one display, frame by frame, without any network on the hot path. Changes come
// in two kinds, told apart by their shape:
//
//  - movement (scrolling, switching windows): a large connected patch of cells changes at once.
//    Masks there drop at once (the app fades them out), so a mask never trails behind content;
//  - animation (a playing video, a ticker, a clock): a few cells keep changing in place. Masks
//    there stay. An unmasked animated cell is judged on its latest frame after `animatedTicks`,
//    then at most every `rejudgeTicks`, rather than waiting for it to hold still.
//
// Each changed cell is resolved once it has held still for `settleTicks` frames: from the verdict
// cache when the same content was judged before, otherwise sent to the model. Verdicts come back
// late; they only apply if the cell still shows what was judged. Cells the reader revealed stay
// unmasked until movement passes over them or the content changes into something else.
import Foundation

public final class Tracker {
  public let spec: GridSpec
  /// Hash distance (of 256 bits) still counted as the same content.
  public let tolerance: Int
  public let settleTicks: Int
  /// A connected patch of at least this many changed cells is movement, not animation.
  public let movementCells: Int
  public let animatedTicks: Int
  public let rejudgeTicks: Int
  public private(set) var hashes: [RegionHash?]
  public private(set) var masked: [Int: Verdict] = [:]
  private var pendingSince: [Int: Int] = [:]
  private var stableFor: [Int]
  private var lastJudged: [Int: Int] = [:]
  private var tick = 0
  private var revealed: [RegionHash] = []
  private var revealedCells: Set<Int> = []
  private var cache: [RegionHash: Verdict] = [:]
  private var cacheOrder: [RegionHash] = []
  private let cacheLimit: Int

  public init(spec: GridSpec, tolerance: Int = 6, settleTicks: Int = 1, movementCells: Int = 6,
              animatedTicks: Int = 4, rejudgeTicks: Int = 85, cacheLimit: Int = 4000) {
    self.spec = spec
    self.tolerance = tolerance
    self.settleTicks = settleTicks
    self.movementCells = movementCells
    self.animatedTicks = animatedTicks
    self.rejudgeTicks = rejudgeTicks
    self.cacheLimit = cacheLimit
    hashes = Array(repeating: nil, count: spec.count)
    stableFor = Array(repeating: 0, count: spec.count)
  }

  public struct Step: Equatable {
    /// The set of masked cells changed; redraw.
    public var masksChanged = false
    /// Cells to send to the model now, with the hashes they had (pass both back to `record`).
    public var toJudge: [Int] = []
    public var judgedHashes: [Int: RegionHash] = [:]
    /// Cells answered from the cache this step.
    public var fromCache = 0
    /// Cells counted as movement this step.
    public var moved = 0
  }

  /// Feed one frame's cell hashes. `judging`: a request is already out; don't start another.
  public func observe(_ frame: [RegionHash?], judging: Bool) -> Step {
    var step = Step()
    tick += 1
    var changed = Set<Int>()
    for i in 0..<spec.count where !same(hashes[i], frame[i]) { changed.insert(i) }
    let firstFrame = hashes.allSatisfy { $0 == nil }
    hashes = frame
    let moving = firstFrame ? changed : movement(in: changed)
    step.moved = moving.count
    for i in 0..<spec.count {
      guard changed.contains(i) else { stableFor[i] += 1; continue }
      stableFor[i] = 0
      if moving.contains(i) {
        if masked.removeValue(forKey: i) != nil { step.masksChanged = true }
        revealedCells.remove(i)
        pendingSince[i] = tick
      } else if masked[i] == nil, pendingSince[i] == nil {
        pendingSince[i] = tick // animated and unmasked: judge it once it settles or has run a while
      }
    }
    guard !judging else { return step }
    for (i, since) in pendingSince.sorted(by: { $0.key < $1.key }) {
      let settled = stableFor[i] >= settleTicks
      let animatedDue = tick - since >= animatedTicks && tick - (lastJudged[i] ?? Int.min / 2) >= rejudgeTicks
      guard settled || animatedDue, let h = hashes[i] else { continue }
      pendingSince.removeValue(forKey: i)
      if let v = cached(h) {
        step.fromCache += 1
        if apply(i, v, hash: h) { step.masksChanged = true }
      } else {
        lastJudged[i] = tick
        step.toJudge.append(i)
        step.judgedHashes[i] = h
      }
    }
    return step
  }

  /// Verdicts for cells judged from `judgedHashes`. Returns whether the masks changed.
  @discardableResult
  public func record(_ verdicts: [Int: Verdict], judgedHashes: [Int: RegionHash]) -> Bool {
    var changed = false
    for (i, v) in verdicts {
      guard let h = judgedHashes[i] else { continue }
      remember(h, v)
      if same(hashes[i], h), apply(i, v, hash: h) { changed = true }
    }
    return changed
  }

  /// The reader clicked a mask: unmask these cells until movement passes over them or the
  /// content changes into something else.
  public func reveal(_ cells: [Int]) {
    for i in cells {
      masked.removeValue(forKey: i)
      revealedCells.insert(i)
      if let h = hashes[i] { revealed.append(h) }
    }
    if revealed.count > 500 { revealed.removeFirst(revealed.count - 500) }
  }

  /// Forget the screen (paused, settings changed): everything is re-judged on the next frames.
  public func reset(keepCache: Bool) {
    hashes = Array(repeating: nil, count: spec.count)
    stableFor = Array(repeating: 0, count: spec.count)
    masked.removeAll()
    pendingSince.removeAll()
    lastJudged.removeAll()
    revealedCells.removeAll()
    if !keepCache { cache.removeAll(); cacheOrder.removeAll() }
  }

  /// Changed cells that sit in a 4-connected patch of at least `movementCells` changed cells.
  func movement(in changed: Set<Int>) -> Set<Int> {
    var seen = Set<Int>(), out = Set<Int>()
    for start in changed where !seen.contains(start) {
      var patch = [start], stack = [start]
      seen.insert(start)
      while let i = stack.popLast() {
        let c = spec.col(i), r = spec.row(i)
        for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
          let nc = c + dc, nr = r + dr
          guard nc >= 0, nc < spec.cols, nr >= 0, nr < spec.rows else { continue }
          let n = nr * spec.cols + nc
          if changed.contains(n), seen.insert(n).inserted { patch.append(n); stack.append(n) }
        }
      }
      if patch.count >= movementCells { out.formUnion(patch) }
    }
    return out
  }

  private func same(_ a: RegionHash?, _ b: RegionHash?) -> Bool {
    guard let a, let b else { return false }
    return a.distance(b) <= tolerance
  }

  private func apply(_ i: Int, _ v: Verdict, hash: RegionHash) -> Bool {
    guard v.hide, !revealedCells.contains(i), !revealed.contains(where: { $0.distance(hash) <= tolerance }) else { return false }
    let was = masked[i]
    masked[i] = v
    return was == nil
  }

  private func cached(_ h: RegionHash) -> Verdict? {
    if let v = cache[h] { return v }
    return cacheOrder.last(where: { $0.distance(h) <= tolerance }).flatMap { cache[$0] }
  }

  private func remember(_ h: RegionHash, _ v: Verdict) {
    if cache.updateValue(v, forKey: h) == nil { cacheOrder.append(h) }
    if cacheOrder.count > cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
  }
}
