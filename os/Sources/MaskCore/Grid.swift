// The screen is cut into a fixed grid of cells. Cells are what gets judged, cached and masked;
// adjacent masked cells merge into one mask rectangle. Coordinates are image pixels, top-left
// origin; the app captures at one pixel per point, so they are also screen points.
import CoreGraphics
import Foundation

public struct GridSpec: Sendable, Equatable, Codable {
  public let cols: Int
  public let rows: Int
  public init(cols: Int, rows: Int) { self.cols = max(1, min(26, cols)); self.rows = max(1, rows) }
  public var count: Int { cols * rows }

  /// "8x5" -> 8 columns, 5 rows.
  public init?(_ text: String) {
    let parts = text.lowercased().split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
    self.init(cols: parts[0], rows: parts[1])
  }

  public func col(_ index: Int) -> Int { index % cols }
  public func row(_ index: Int) -> Int { index / cols }

  /// Spreadsheet-style label: column letter, row number ("C2").
  public func label(_ index: Int) -> String {
    "\(Character(UnicodeScalar(65 + col(index))!))\(row(index) + 1)"
  }

  public func rect(_ index: Int, width: Int, height: Int) -> CGRect {
    let c = col(index), r = row(index)
    let x0 = width * c / cols, x1 = width * (c + 1) / cols
    let y0 = height * r / rows, y1 = height * (r + 1) / rows
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }

  /// Rectangle spanning a block of cells.
  public func rect(_ block: CellBlock, width: Int, height: Int) -> CGRect {
    rect(block.row0 * cols + block.col0, width: width, height: height)
      .union(rect(block.row1 * cols + block.col1, width: width, height: height))
  }
}

/// An axis-aligned block of cells, inclusive.
public struct CellBlock: Hashable, Sendable {
  public let col0: Int, row0: Int, col1: Int, row1: Int
  public init(col0: Int, row0: Int, col1: Int, row1: Int) {
    self.col0 = col0; self.row0 = row0; self.col1 = col1; self.row1 = row1
  }
  public func cells(_ spec: GridSpec) -> [Int] {
    (row0...row1).flatMap { r in (col0...col1).map { r * spec.cols + $0 } }
  }
}

public enum Merge {
  /// Cover the masked cells with as few rectangles as a simple greedy pass finds: runs along each
  /// row, then identical runs stacked on consecutive rows join. Exact cover, no unmasked cell.
  public static func blocks(_ masked: Set<Int>, spec: GridSpec) -> [CellBlock] {
    var runs: [CellBlock] = []
    for r in 0..<spec.rows {
      var c = 0
      while c < spec.cols {
        guard masked.contains(r * spec.cols + c) else { c += 1; continue }
        let start = c
        while c + 1 < spec.cols, masked.contains(r * spec.cols + c + 1) { c += 1 }
        runs.append(CellBlock(col0: start, row0: r, col1: c, row1: r))
        c += 1
      }
    }
    var out: [CellBlock] = []
    for run in runs {
      if let i = out.firstIndex(where: { $0.col0 == run.col0 && $0.col1 == run.col1 && $0.row1 == run.row0 - 1 }) {
        out[i] = CellBlock(col0: run.col0, row0: out[i].row0, col1: run.col1, row1: run.row0)
      } else {
        out.append(run)
      }
    }
    return out
  }
}

/// A 256-bit difference hash of a region: 17x16 grayscale, one bit per horizontal neighbour pair.
/// Plain image arithmetic, no model. Used to notice change and to cache verdicts by content.
public struct RegionHash: Hashable, Sendable {
  public let bits: [UInt64] // 4 words

  public func distance(_ other: RegionHash) -> Int {
    zip(bits, other.bits).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
  }

  public static func of(_ image: CGImage, rect: CGRect) -> RegionHash? {
    let w = 17, h = 16
    guard let crop = image.cropping(to: rect.integral),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: w * h)
    var words = [UInt64](repeating: 0, count: 4)
    var bit = 0
    for y in 0..<h {
      for x in 0..<(w - 1) {
        if px[y * w + x] > px[y * w + x + 1] { words[bit / 64] |= 1 << UInt64(bit % 64) }
        bit += 1
      }
    }
    return RegionHash(bits: words)
  }
}
