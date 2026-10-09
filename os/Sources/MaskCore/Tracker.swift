// What to mask on one display, frame by frame, without any network on the hot path:
//
//  - a cell whose pixels change loses its mask at once (the app fades it out), so a mask never
//    trails behind scrolled content;
//  - once the screen has held still for `settleTicks` frames, changed cells are resolved: from
//    the verdict cache when the same content was judged before, otherwise sent to the model;
//  - verdicts come back late; they only apply if the cell still shows what was judged.
//
// Cells the reader revealed stay unmasked until their content changes.
import Foundation

public final class Tracker {
  public let spec: GridSpec
  /// Hash distance (of 256 bits) still counted as the same content.
  public let tolerance: Int
  public let settleTicks: Int
  public private(set) var hashes: [RegionHash?]
  public private(set) var masked: [Int: Verdict] = [:]
  private var pending: Set<Int>
  private var stable = 0
  private var revealed: [RegionHash] = []
  private var cache: [RegionHash: Verdict] = [:]
  private var cacheOrder: [RegionHash] = []
  private let cacheLimit: Int

  public init(spec: GridSpec, tolerance: Int = 6, settleTicks: Int = 1, cacheLimit: Int = 4000) {
    self.spec = spec
    self.tolerance = tolerance
    self.settleTicks = settleTicks
    self.cacheLimit = cacheLimit
    hashes = Array(repeating: nil, count: spec.count)
    pending = Set(0..<spec.count)
  }

  public struct Step: Equatable {
    /// The set of masked cells changed; redraw.
    public var masksChanged = false
    /// Cells to send to the model now, with the hashes they had (pass both back to `record`).
    public var toJudge: [Int] = []
    public var judgedHashes: [Int: RegionHash] = [:]
    /// Cells answered from the cache this step.
    public var fromCache = 0
  }

  /// Feed one frame's cell hashes. `judging`: a request is already out; don't start another.
  public func observe(_ frame: [RegionHash?], judging: Bool) -> Step {
    var step = Step()
    var changed = Set<Int>()
    for i in 0..<spec.count where !same(hashes[i], frame[i]) { changed.insert(i) }
    hashes = frame
    if !changed.isEmpty {
      for i in changed where masked.removeValue(forKey: i) != nil { step.masksChanged = true }
      pending.formUnion(changed)
      stable = 0
      return step
    }
    stable += 1
    guard stable >= settleTicks, !pending.isEmpty, !judging else { return step }
    for i in pending.sorted() {
      guard let h = hashes[i] else { continue }
      if let v = cached(h) {
        step.fromCache += 1
        if apply(i, v, hash: h) { step.masksChanged = true }
      } else {
        step.toJudge.append(i)
        step.judgedHashes[i] = h
      }
    }
    pending.removeAll()
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

  /// The reader clicked a mask: unmask these cells until their content changes.
  public func reveal(_ cells: [Int]) {
    for i in cells {
      masked.removeValue(forKey: i)
      if let h = hashes[i] { revealed.append(h) }
    }
    if revealed.count > 500 { revealed.removeFirst(revealed.count - 500) }
  }

  /// Forget the screen (paused, settings changed): everything is re-judged on the next frames.
  public func reset(keepCache: Bool) {
    hashes = Array(repeating: nil, count: spec.count)
    masked.removeAll()
    pending = Set(0..<spec.count)
    stable = 0
    if !keepCache { cache.removeAll(); cacheOrder.removeAll() }
  }

  private func same(_ a: RegionHash?, _ b: RegionHash?) -> Bool {
    guard let a, let b else { return false }
    return a.distance(b) <= tolerance
  }

  private func apply(_ i: Int, _ v: Verdict, hash: RegionHash) -> Bool {
    guard v.hide, !revealed.contains(where: { $0.distance(hash) <= tolerance }) else { return false }
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
