// Checking each mask before it shows. The grid and the zoomed look decide where a mask goes; this
// asks once more, about the mask's own shape: a crop around it with the shape outlined in red,
// "is what's inside the outline an ad?". It throws out shapes that landed on a recipe photo or a
// headline. In @lillyguisnet's beetle tests (Vision Jev, 2026-10-16) checking each box raised
// precision but found nothing new and rejected one real beetle, so each shape gets two differently
// worded questions in one request (Decisions bills input only, so the second is free) and is
// dropped only when both say no. A shape whose request fails is kept: the earlier passes said hide.
import CoreGraphics
import Foundation

public enum Verify {
  public struct Outcome: Sendable {
    public var kept: [CGRect] = []
    public var dropped: [CGRect] = []
    /// Per input rect, in order: the higher of the two answers (nil when its request failed).
    public var scores: [Double?] = []
    public var errors: [String] = []
    public var requests = 0
    public var seconds = 0.0
  }

  static let text = "A crop of someone's computer screen. The region outlined in red is the one being checked; everything outside the outline is only context."

  public static func questions(_ matched: [Bubble]) -> [Question] {
    matched.map {
      .predicate(name: $0.id, instructions: "Is what's inside the red outline mostly \($0.description)? Answer yes if the outline sits on one, even if it cuts part of it off; no if it's mostly ordinary content, a photo or headline that belongs to the page, or interface.")
    } + [.choice(name: "kind", instructions: "What does the region inside the red outline mostly show?",
                 choices: [("keep", "anything else: ordinary content, text, a photo that belongs to the page, interface, empty space")]
                   + matched.map { ($0.id, $0.description) })]
  }

  /// The higher of "a predicate said yes" and "the choice wasn't keep".
  public static func score(_ answers: [String: Answer], matched: [Bubble]) -> Double? {
    let preds = matched.compactMap { answers[$0.id]?.probability }
    var choice: Double?
    if let a = answers["kind"] {
      let probs = a.probabilities.isEmpty ? [a.choice ?? "keep": 1] : a.probabilities
      choice = matched.reduce(0) { $0 + (probs[$1.id] ?? 0) }
    }
    let all = preds + (choice.map { [$0] } ?? [])
    return all.max()
  }

  /// Check `rects` (image pixels) against the bubbles that matched them, one request each.
  public static func rects(_ rects: [CGRect], image: CGImage, matched: [Bubble], client: DecisionsClient,
                           threshold: Double = 0.5, margin: CGFloat = 0.35, maxConcurrent: Int = 6) async -> Outcome {
    var out = Outcome()
    guard !matched.isEmpty, !rects.isEmpty else { out.kept = rects; return out }
    let start = Date()
    let qs = questions(matched)
    var scores = [Double?](repeating: nil, count: rects.count)
    let jobs: [(Int, String?)] = rects.enumerated().map { i, r in
      (i, Imaging.tile(image, cell: r, margin: margin, maxSide: 768).flatMap { Imaging.jpegDataURL($0, quality: 0.8) })
    }
    out.requests = jobs.filter { $0.1 != nil }.count
    await forEachLimited(jobs, limit: maxConcurrent) { job -> (Int, Result<[String: Answer], Error>) in
      guard let url = job.1 else { return (job.0, .failure(DecisionsError(description: "could not crop the shape"))) }
      do { return (job.0, .success(try await client.ask(text: text, imageDataURL: url, questions: qs))) }
      catch { return (job.0, .failure(error)) }
    } collect: { i, outcome in
      switch outcome {
      case .success(let answers): scores[i] = score(answers, matched: matched)
      case .failure(let e): out.errors.append("\(e)")
      }
    }
    for (r, s) in zip(rects, scores) {
      if let s, s < threshold { out.dropped.append(r) } else { out.kept.append(r) }
    }
    out.scores = scores
    out.seconds = Date().timeIntervalSince(start)
    return out
  }
}
