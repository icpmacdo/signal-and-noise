// Asking the model which cells to mask. Two ways to find regions from pixels alone:
//
//  tiles: one request per cell, a crop of the cell with context around it, the cell outlined.
//         One predicate per bubble ("does the outlined region show an ad?"). Whole-image
//         questions, the kind the model is documented on; requests run in parallel.
//  grid:  one image of the whole screen with a labelled grid; one choice question per cell
//         ("what does cell C2 mostly show?"), chunked across a few requests. Fewer images, but
//         it leans on the model pointing at parts of an image, which is unproven.
//
// A cell whose request fails gets no verdict and stays unmasked (fail open).
import CoreGraphics
import Foundation

public enum Mode: String, Codable, CaseIterable, Sendable {
  case tiles, grid
}

/// How grid mode asks about a cell: one choice over keep + bubbles ("what does it mostly show?"),
/// or one yes/no per bubble ("does it show any part of an ad?").
public enum GridAsk: String, Codable, CaseIterable, Sendable {
  case choice, predicate
}

public struct Verdict: Codable, Equatable, Sendable {
  public let hide: Bool
  /// Labels of the bubbles that matched.
  public let reasons: [String]
  /// Bubble id -> probability that the cell shows it.
  public let scores: [String: Double]

  public init(hide: Bool, reasons: [String], scores: [String: Double]) {
    self.hide = hide
    self.reasons = reasons
    self.scores = scores
  }
}

public struct JudgeResult: Sendable {
  public var verdicts: [Int: Verdict] = [:]
  public var errors: [String] = []
  public var requests = 0
  public var seconds: Double = 0
}

public struct Judge: Sendable {
  public let client: DecisionsClient
  public let bubbles: [Bubble]
  /// A bubble matches when its probability reaches this.
  public let threshold: Double
  public let mode: Mode
  public let maxConcurrent: Int
  /// Grid mode: questions per request.
  public let chunk: Int
  public let gridAsk: GridAsk

  public init(client: DecisionsClient, bubbles: [Bubble], threshold: Double = 0.6, mode: Mode = .tiles,
              maxConcurrent: Int = 12, chunk: Int = 20, gridAsk: GridAsk = .choice) {
    self.client = client
    self.bubbles = bubbles
    self.threshold = threshold
    self.mode = mode
    self.maxConcurrent = maxConcurrent
    self.chunk = chunk
    self.gridAsk = gridAsk
  }

  static let tileText = "A crop of someone's computer screen. The region outlined in red is the one being checked; everything outside the outline is only context."

  public func tileQuestions() -> [Question] {
    bubbles.map {
      .predicate(name: $0.id, instructions: "Does the region inside the red outline show \($0.description)? Judge only what is inside the outline; if it shows only part of such a thing, answer yes.")
    }
  }

  public func gridText(_ spec: GridSpec) -> String {
    let lastCol = Character(UnicodeScalar(64 + spec.cols)!)
    return "A screenshot of someone's computer screen with a red grid drawn over it: columns A to \(lastCol) left to right, rows 1 to \(spec.rows) top to bottom, each cell labelled in its top-left corner. Each question asks about one cell."
  }

  public func gridQuestion(_ index: Int, spec: GridSpec) -> Question {
    let label = spec.label(index)
    return .choice(name: label, instructions: "What does grid cell \(label) mostly show? If part of the cell shows one of the listed things, pick that thing.",
                   choices: [("keep", "anything else: ordinary content, text, interface, empty space")] + bubbles.map { ($0.id, $0.description) })
  }

  public func gridPredicates(_ index: Int, spec: GridSpec) -> [Question] {
    let label = spec.label(index)
    return bubbles.map {
      .predicate(name: "\(label)_\($0.id)", instructions: "Does grid cell \(label) show any part of \($0.description)? Answer yes if it covers any of the cell; no if the cell shows only other content, interface or empty space.")
    }
  }

  /// Turn per-bubble probabilities into a verdict.
  public func verdict(_ scores: [String: Double]) -> Verdict {
    let hits = bubbles.filter { (scores[$0.id] ?? 0) >= threshold }
    return Verdict(hide: !hits.isEmpty, reasons: hits.map(\.label), scores: scores)
  }

  /// Judge `cells` of `image`. Only cells that got an answer appear in the result.
  public func judge(_ image: CGImage, spec: GridSpec, cells: [Int]) async -> JudgeResult {
    guard !bubbles.isEmpty, !cells.isEmpty else { return JudgeResult() }
    let start = Date()
    var result = mode == .tiles ? await judgeTiles(image, spec: spec, cells: cells) : await judgeGrid(image, spec: spec, cells: cells)
    result.seconds = Date().timeIntervalSince(start)
    return result
  }

  func judgeTiles(_ image: CGImage, spec: GridSpec, cells: [Int]) async -> JudgeResult {
    let questions = tileQuestions()
    let jobs: [(Int, String)] = cells.compactMap { i in
      let rect = spec.rect(i, width: image.width, height: image.height)
      guard let tile = Imaging.tile(image, cell: rect), let url = Imaging.jpegDataURL(tile) else { return nil }
      return (i, url)
    }
    var result = JudgeResult()
    result.requests = jobs.count
    await forEachLimited(jobs, limit: maxConcurrent) { job -> (Int, Result<[String: Answer], Error>) in
      do { return (job.0, .success(try await client.ask(text: Self.tileText, imageDataURL: job.1, questions: questions))) }
      catch { return (job.0, .failure(error)) }
    } collect: { cell, outcome in
      switch outcome {
      case .success(let answers):
        let scores = Dictionary(uniqueKeysWithValues: bubbles.compactMap { b in answers[b.id]?.probability.map { (b.id, $0) } })
        if !scores.isEmpty { result.verdicts[cell] = verdict(scores) }
      case .failure(let e):
        result.errors.append("\(spec.label(cell)): \(e)")
      }
    }
    return result
  }

  func judgeGrid(_ image: CGImage, spec: GridSpec, cells: [Int]) async -> JudgeResult {
    var result = JudgeResult()
    guard let gridImage = Imaging.grid(image, spec: spec), let url = Imaging.jpegDataURL(gridImage) else {
      result.errors.append("could not draw the grid image")
      return result
    }
    let text = gridText(spec)
    // Keep about `chunk` questions per request whichever way cells are asked about.
    let perCell = gridAsk == .predicate ? bubbles.count : 1
    let cellsPer = max(1, chunk / perCell)
    let chunks = stride(from: 0, to: cells.count, by: cellsPer).map { Array(cells[$0..<min($0 + cellsPer, cells.count)]) }
    result.requests = chunks.count
    let ask = gridAsk
    await forEachLimited(chunks, limit: maxConcurrent) { part -> ([Int], Result<[String: Answer], Error>) in
      let questions = ask == .predicate ? part.flatMap { gridPredicates($0, spec: spec) } : part.map { gridQuestion($0, spec: spec) }
      do { return (part, .success(try await client.ask(text: text, imageDataURL: url, questions: questions))) }
      catch { return (part, .failure(error)) }
    } collect: { part, outcome in
      switch outcome {
      case .success(let answers):
        for i in part {
          let label = spec.label(i)
          if ask == .predicate {
            let scores = Dictionary(uniqueKeysWithValues: bubbles.compactMap { b in answers["\(label)_\(b.id)"]?.probability.map { (b.id, $0) } })
            if !scores.isEmpty { result.verdicts[i] = verdict(scores) }
          } else if let a = answers[label] {
            result.verdicts[i] = verdict(Dictionary(uniqueKeysWithValues: bubbles.map { ($0.id, a.probabilities[$0.id] ?? (a.choice == $0.id ? 1 : 0)) }))
          }
        }
      case .failure(let e):
        result.errors.append("cells \(part.map { spec.label($0) }.joined(separator: ",")): \(e)")
      }
    }
    return result
  }
}

/// Run `work` over `items` with at most `limit` in flight; `collect` sees each result serially.
func forEachLimited<T: Sendable, K: Sendable, R: Sendable>(
  _ items: [T], limit: Int, work: @escaping @Sendable (T) async -> (K, R), collect: (K, R) -> Void
) async {
  await withTaskGroup(of: (K, R).self) { group in
    var next = 0
    for _ in 0..<min(max(1, limit), items.count) {
      let item = items[next]; next += 1
      group.addTask { await work(item) }
    }
    while let (k, r) = await group.next() {
      collect(k, r)
      if next < items.count {
        let item = items[next]; next += 1
        group.addTask { await work(item) }
      }
    }
  }
}
