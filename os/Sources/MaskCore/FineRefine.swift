// The zoomed second pass. The coarse grid is good at noticing that an ad is somewhere in a cell,
// and bad at its edges: on a 6K display an 8x5 cell is 376x338 points, so a mask built from
// cells covers browser tabs and headlines while the rest of the ad pokes out beside it. Here a
// masked block plus a margin is cropped at full resolution, a fine grid (about `sub` x `sub`
// subcells per coarse cell) is drawn on it, and the model says which subcells show part of the
// thing that matched. The mask becomes those subcells. Same model and key as the coarse pass.
import CoreGraphics
import Foundation

public enum FineRefine {
  public struct Outcome: Sendable {
    /// Image-pixel rects to mask instead of the block. Empty: keep the block.
    public var rects: [CGRect] = []
    public var errors: [String] = []
    public var requests = 0
    public var seconds = 0.0
  }

  /// The crop looked at for a block: the block plus `margin` cells on each side, clamped.
  public static func area(_ block: CellBlock, spec: GridSpec, width: Int, height: Int, margin: CGFloat) -> CGRect {
    let r = spec.rect(block, width: width, height: height)
    let cell = spec.rect(0, width: width, height: height)
    return r.insetBy(dx: -cell.width * margin, dy: -cell.height * margin)
      .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
  }

  /// The fine grid over `area`: subcells about a `sub`th of a coarse cell, at most 26 columns.
  public static func fineSpec(area: CGRect, spec: GridSpec, width: Int, height: Int, sub: Int) -> GridSpec {
    let cell = spec.rect(0, width: width, height: height)
    return GridSpec(cols: min(26, max(1, Int((area.width / (cell.width / CGFloat(sub))).rounded()))),
                    rows: max(1, Int((area.height / (cell.height / CGFloat(sub))).rounded())))
  }

  public static func block(_ block: CellBlock, image: CGImage, spec: GridSpec, matched: [Bubble], client: DecisionsClient,
                           threshold: Double = 0.5, sub: Int = 3, margin: CGFloat = 0.5, chunk: Int = 40,
                           maxConcurrent: Int = 6) async -> Outcome {
    var result = Outcome()
    guard !matched.isEmpty else { return result }
    let start = Date()
    let area = area(block, spec: spec, width: image.width, height: image.height, margin: margin)
    let fine = fineSpec(area: area, spec: spec, width: image.width, height: image.height, sub: sub)
    guard let crop = image.cropping(to: area), let gridImage = Imaging.grid(crop, spec: fine),
          let url = Imaging.jpegDataURL(gridImage, quality: 0.8) else { return result }
    let what = matched.map(\.description).joined(separator: "; or ")
    let lastCol = Character(UnicodeScalar(64 + fine.cols)!)
    let text = "A zoomed-in part of someone's computer screen with a red grid drawn over it: columns A to \(lastCol) left to right, rows 1 to \(fine.rows) top to bottom, each cell labelled in its top-left corner. Each question asks about one cell."
    let questions: [Question] = (0..<fine.count).map { i in
      .predicate(name: fine.label(i), instructions: "Does grid cell \(fine.label(i)) show any part of \(what)? Answer yes if the thing covers any of the cell, including its border or background; no if the cell shows only other content, page interface or empty space.")
    }
    let chunks = stride(from: 0, to: questions.count, by: chunk).map { Array(questions[$0..<min($0 + chunk, questions.count)]) }
    result.requests = chunks.count
    var hits = Set<Int>()
    let labels = Dictionary(uniqueKeysWithValues: (0..<fine.count).map { (fine.label($0), $0) })
    await forEachLimited(chunks, limit: maxConcurrent) { part -> (Int, Result<[String: Answer], Error>) in
      do { return (0, .success(try await client.ask(text: text, imageDataURL: url, questions: part))) }
      catch { return (0, .failure(error)) }
    } collect: { _, outcome in
      switch outcome {
      case .success(let answers):
        for (name, a) in answers where (a.probability ?? 0) >= threshold { if let i = labels[name] { hits.insert(i) } }
      case .failure(let e):
        result.errors.append("\(e)")
      }
    }
    result.rects = Merge.blocks(hits, spec: fine).map { b in
      fine.rect(b, width: Int(area.width), height: Int(area.height)).offsetBy(dx: area.minX, dy: area.minY)
    }
    result.seconds = Date().timeIntervalSince(start)
    return result
  }
}

/// Pixel-area agreement between masks and labelled boxes, for the eval.
public enum Coverage {
  /// (recall, precision): how much labelled area is masked, and how much masked area is labelled.
  /// Rasterised at `step` pixels, so overlapping rects count once.
  public static func score(masked: [CGRect], truth: [CGRect], width: Int, height: Int, step: Int = 4) -> (maskedArea: Int, truthArea: Int, overlap: Int) {
    var m = 0, t = 0, both = 0
    for y in stride(from: step / 2, to: height, by: step) {
      for x in stride(from: step / 2, to: width, by: step) {
        let p = CGPoint(x: x, y: y)
        let inM = masked.contains { $0.contains(p) }, inT = truth.contains { $0.contains(p) }
        if inM { m += 1 }
        if inT { t += 1 }
        if inM && inT { both += 1 }
      }
    }
    return (m, t, both)
  }
}
