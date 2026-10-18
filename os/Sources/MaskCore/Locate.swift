// Shapes from boxes. TypeSafe's Jev 1.14 can answer "where is the ad?" with one box, so instead
// of a fine grid over a flagged block (FineRefine), each block is searched for boxes in a loop,
// following @lillyguisnet's beetle tests and @lotusfracture's notes on the Vision Jev thread
// (2026-10-16):
//
//  1. Crop the block plus a margin at full resolution. Ask, in one request, "is there any ad
//     here?" (noul) and "where is it?" (box). Box always answers, so the noul decides: below the
//     bar, this region is done.
//  2. Check the box (Verify: crop it, outline it, "is this an ad?"). Kept: paint it out and ask the
//     same region again for the next one. Rejected: cut the region in half along its long side and
//     search each half, a few levels down at most.
//  3. Stop at `maxBoxes` boxes or `maxRequests` requests per block.
//
// The coarse grid still decides *whether* a block is hidden; this decides its shape. Nothing found
// means nothing is masked; every request failing means the caller keeps the block.
import CoreGraphics
import Foundation

public enum Locate {
  public struct Outcome: Sendable {
    /// Image-pixel rects to mask instead of the block.
    public var rects: [CGRect] = []
    /// Boxes the check rejected.
    public var rejected: [CGRect] = []
    public var errors: [String] = []
    public var requests = 0
    public var seconds = 0.0
  }

  static func what(_ matched: [Bubble]) -> String { matched.map(\.description).joined(separator: "; or ") }

  public static func questions(_ matched: [Bubble]) -> [Question] {
    let w = what(matched)
    return [
      .predicate(name: "present", instructions: "Does this picture show any part of \(w)? Plain patches painted over it hide things already found; they don't count."),
      .box(name: "where", instructions: "\(w) in this picture, a crop of someone's computer screen. If there are several, the largest one. Ignore plain patches painted over it."),
    ]
  }

  static let text = "A crop of someone's computer screen."

  /// Search `block` (plus `margin` cells around it) for boxes. `checkClient` checks each box; nil
  /// takes every box the presence question vouches for.
  public static func block(_ block: CellBlock, image: CGImage, spec: GridSpec, matched: [Bubble], client: DecisionsClient,
                           checkClient: DecisionsClient?, margin: CGFloat = 0.5, presentThreshold: Double = 0.5,
                           checkThreshold: Double = 0.5, maxBoxes: Int = 4, maxDepth: Int = 2, maxRequests: Int = 12) async -> Outcome {
    var out = Outcome()
    guard !matched.isEmpty else { return out }
    let start = Date()
    let area = FineRefine.area(block, spec: spec, width: image.width, height: image.height, margin: margin)
    let qs = questions(matched)
    var regions: [(CGRect, Int)] = [(area, 0)]
    search: while let (region, depth) = regions.popLast() {
      while out.rects.count < maxBoxes {
        guard out.requests < maxRequests else { break search }
        // Paint what was already found, then crop: the region at full resolution, sized for Jev.
        let found = out.rects.filter { $0.intersects(region) }.map { $0.offsetBy(dx: -region.minX, dy: -region.minY) }
        guard let crop = image.cropping(to: region), let painted = Imaging.paintOut(crop, rects: found),
              let fitted = Imaging.fitForJev(painted), let url = Imaging.jpegDataURL(fitted.image, quality: 0.85) else {
          out.errors.append("could not crop \(region)"); break
        }
        out.requests += 1
        let answers: [String: Answer]
        do { answers = try await client.ask(text: text, imageDataURL: url, questions: qs) } catch {
          out.errors.append("\(error)"); break
        }
        guard let present = answers["present"]?.probability, present >= presentThreshold, let unit = answers["where"]?.box else { break }
        // Fractions of the fitted image -> crop pixels -> image pixels.
        let fw = CGFloat(fitted.image.width) / fitted.scale, fh = CGFloat(fitted.image.height) / fitted.scale
        let box = CGRect(x: region.minX + unit.minX * fw, y: region.minY + unit.minY * fh, width: unit.width * fw, height: unit.height * fh)
          .intersection(region).integral
        guard box.width >= 8, box.height >= 8, !out.rects.contains(where: { iou($0, box) > 0.6 }) else { break }
        if let checkClient {
          guard out.requests < maxRequests else { break search }
          let v = await Verify.rects([box], image: image, matched: matched, client: checkClient, threshold: checkThreshold)
          out.requests += v.requests
          out.errors += v.errors
          if v.kept.isEmpty {
            out.rejected.append(box)
            if depth < maxDepth { regions += halves(region).map { ($0, depth + 1) } }
            break
          }
        }
        out.rects.append(box)
      }
      if out.rects.count >= maxBoxes { break }
    }
    out.seconds = Date().timeIntervalSince(start)
    return out
  }

  /// A region cut in two along its long side.
  public static func halves(_ r: CGRect) -> [CGRect] {
    r.width >= r.height
      ? [CGRect(x: r.minX, y: r.minY, width: (r.width / 2).rounded(.down), height: r.height),
         CGRect(x: r.minX + (r.width / 2).rounded(.down), y: r.minY, width: r.width - (r.width / 2).rounded(.down), height: r.height)]
      : [CGRect(x: r.minX, y: r.minY, width: r.width, height: (r.height / 2).rounded(.down)),
         CGRect(x: r.minX, y: r.minY + (r.height / 2).rounded(.down), width: r.width, height: r.height - (r.height / 2).rounded(.down))]
  }

  static func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let inter = Double(i.width * i.height)
    return inter / (Double(a.width * a.height) + Double(b.width * b.height) - inter)
  }
}
