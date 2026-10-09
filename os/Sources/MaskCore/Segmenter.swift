// Tighter mask shapes with SAM 3 (Meta's Segment Anything, hosted by fal.ai: fal-ai/sam-3/image,
// $0.005 per call). The grid decides *whether* to hide; SAM only reshapes a masked block. It gets
// a crop of the block plus some margin and the bubble as a noun phrase ("advertisement"), and the
// boxes it finds replace the blocky cells. No boxes, an error or no key: the grid mask stays.
import CoreGraphics
import Foundation

public struct SAMBox: Equatable, Sendable {
  /// Pixel rect in the image that was sent (top-left origin).
  public let rect: CGRect
  public let score: Double
}

public final class SAMClient: @unchecked Sendable {
  public static let defaultURL = URL(string: "https://fal.run/fal-ai/sam-3/image")!
  public let key: String
  public let url: URL
  let session: URLSession
  let timeout: TimeInterval

  public init(key: String, url: URL = SAMClient.defaultURL, session: URLSession = .shared, timeout: TimeInterval = 20) {
    self.key = key
    self.url = url
    self.session = session
    self.timeout = timeout
  }

  public static func body(imageDataURL: String, prompt: String, maxMasks: Int = 8) -> [String: Any] {
    ["image_url": imageDataURL, "prompt": prompt, "include_boxes": true, "include_scores": true,
     "return_multiple_masks": true, "max_masks": maxMasks, "apply_mask": false, "sync_mode": true]
  }

  /// Boxes come back normalized as [cx, cy, w, h], either top-level (`boxes` + `scores`) or per
  /// mask in `metadata`. Converted to pixel rects of an image `width` x `height`.
  public static func parse(_ data: Data, width: Int, height: Int) throws -> [SAMBox] {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw DecisionsError(description: "SAM: not JSON: \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    var pairs: [([Double], Double)] = []
    if let boxes = json["boxes"] as? [[NSNumber]] {
      let scores = (json["scores"] as? [NSNumber])?.map(\.doubleValue) ?? []
      for (i, b) in boxes.enumerated() { pairs.append((b.map(\.doubleValue), i < scores.count ? scores[i] : 1)) }
    } else if let meta = json["metadata"] as? [[String: Any]] {
      for m in meta {
        if let b = m["box"] as? [NSNumber] { pairs.append((b.map(\.doubleValue), (m["score"] as? NSNumber)?.doubleValue ?? 1)) }
      }
    } else if json["masks"] == nil {
      throw DecisionsError(description: "SAM: unexpected response: \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    return pairs.compactMap { b, score in
      guard b.count == 4 else { return nil }
      let w = b[2] * Double(width), h = b[3] * Double(height)
      return SAMBox(rect: CGRect(x: b[0] * Double(width) - w / 2, y: b[1] * Double(height) - h / 2, width: w, height: h), score: score)
    }
  }

  public func segment(_ image: CGImage, prompt: String) async throws -> [SAMBox] {
    guard let dataURL = Imaging.jpegDataURL(image, quality: 0.85) else { return [] }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !key.isEmpty { req.setValue("Key \(key)", forHTTPHeaderField: "Authorization") }
    req.httpBody = try JSONSerialization.data(withJSONObject: Self.body(imageDataURL: dataURL, prompt: prompt))
    let (data, resp) = try await session.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw DecisionsError(description: "SAM HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    return try Self.parse(data, width: image.width, height: image.height)
  }
}

public enum Refine {
  /// The area SAM looks at for a masked block: the block plus half a cell on each side, so a
  /// thing that spills slightly past the cells it was flagged in is still covered.
  public static func searchArea(_ block: CellBlock, spec: GridSpec, width: Int, height: Int) -> CGRect {
    let r = spec.rect(block, width: width, height: height)
    let cell = spec.rect(0, width: width, height: height)
    return r.insetBy(dx: -cell.width / 2, dy: -cell.height / 2)
      .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
  }

  /// Turn SAM boxes (in the crop's pixels) into image rects: drop weak or tiny ones, clip to the
  /// search area. Boxes that cover nearly the whole crop say nothing about shape and are dropped.
  public static func shapes(_ boxes: [SAMBox], area: CGRect, minScore: Double = 0.35) -> [CGRect] {
    boxes.compactMap { b in
      guard b.score >= minScore else { return nil }
      let r = b.rect.offsetBy(dx: area.minX, dy: area.minY).intersection(area)
      guard !r.isNull, r.width >= 24, r.height >= 24, r.width * r.height < area.width * area.height * 0.92 else { return nil }
      return r.integral
    }
  }

  /// Reshape one masked block. `prompts` are the noun phrases of the bubbles that matched in it.
  /// Empty `rects` means keep the grid mask (no phrase, nothing found, or every call failed).
  public static func block(_ block: CellBlock, image: CGImage, spec: GridSpec, prompts: [String],
                           client: SAMClient) async -> (rects: [CGRect], errors: [String]) {
    let area = searchArea(block, spec: spec, width: image.width, height: image.height)
    guard !prompts.isEmpty, let crop = image.cropping(to: area) else { return ([], []) }
    var rects: [CGRect] = []
    var errors: [String] = []
    for p in prompts {
      do { rects += shapes(try await client.segment(crop, prompt: p), area: area) }
      catch { errors.append("\(error)") }
    }
    return (rects, errors)
  }
}
