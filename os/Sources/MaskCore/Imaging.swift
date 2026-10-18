// Preparing screen pixels for the model: a tile (one cell plus surrounding context, the cell
// outlined in red) or the whole screen with a labelled grid drawn on it. Sent as JPEG data: URLs,
// the only image form /v1/decisions accepts.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Imaging {
  /// A cell with `margin` (fraction of the cell size) of context on each side, clamped to the
  /// image, the cell itself outlined in red. Scaled down so the long side is at most `maxSide`.
  public static func tile(_ image: CGImage, cell: CGRect, margin: CGFloat = 0.5, maxSide: Int = 512) -> CGImage? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let outer = cell.insetBy(dx: -cell.width * margin, dy: -cell.height * margin).intersection(bounds).integral
    guard let crop = image.cropping(to: outer) else { return nil }
    let scale = min(1, CGFloat(maxSide) / max(outer.width, outer.height))
    let w = Int(outer.width * scale), h = Int(outer.height * scale)
    guard let ctx = rgbContext(w, h) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    // CGContext's origin is bottom-left; cell rects are top-left.
    let local = CGRect(x: (cell.minX - outer.minX) * scale, y: (outer.maxY - cell.maxY) * scale,
                       width: cell.width * scale, height: cell.height * scale)
    ctx.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
    ctx.setLineWidth(3)
    ctx.stroke(local.insetBy(dx: 1.5, dy: 1.5))
    return ctx.makeImage()
  }

  /// The whole image with grid lines and a label ("A1") in each cell's top-left corner.
  public static func grid(_ image: CGImage, spec: GridSpec, maxSide: Int = 1600) -> CGImage? {
    let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
    let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
    guard let ctx = rgbContext(w, h) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 0.9))
    ctx.setLineWidth(2)
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)
    for i in 0..<spec.count {
      let r = spec.rect(i, width: w, height: h)
      let flipped = CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height)
      ctx.stroke(flipped)
      let text = NSAttributedString(string: spec.label(i), attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
      ])
      let line = CTLineCreateWithAttributedString(text)
      let tw = CTLineGetTypographicBounds(line, nil, nil, nil)
      ctx.setFillColor(CGColor(red: 0.85, green: 0.05, blue: 0.05, alpha: 0.9))
      ctx.fill(CGRect(x: flipped.minX + 2, y: flipped.maxY - 22, width: CGFloat(tw) + 8, height: 20))
      ctx.textPosition = CGPoint(x: flipped.minX + 6, y: flipped.maxY - 17)
      CTLineDraw(line, ctx)
    }
    return ctx.makeImage()
  }

  /// The image with each rect (top-left origin) filled with the colour around its edges: the median
  /// of a thin ring just outside it. Used to hide what was already found before asking again, so
  /// the patch reads as page background rather than as a new grey box.
  public static func paintOut(_ image: CGImage, rects: [CGRect]) -> CGImage? {
    let w = image.width, h = image.height
    guard let ctx = rgbContext(w, h) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard !rects.isEmpty, let data = ctx.data else { return ctx.makeImage() }
    let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
    let bounds = CGRect(x: 0, y: 0, width: w, height: h)
    // Sample every ring first, so one patch's paint doesn't colour the next one's ring.
    let fills: [(CGRect, CGColor)] = rects.compactMap { r in
      let rect = r.intersection(bounds).integral
      guard !rect.isEmpty else { return nil }
      let ring = rect.insetBy(dx: -4, dy: -4).intersection(bounds).integral
      var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
      let step = max(1, Int(max(ring.width, ring.height)) / 400)
      func sample(_ x: Int, _ y: Int) {
        // Bitmap memory is top row first, so top-left image coordinates index it directly.
        let o = y * ctx.bytesPerRow + x * 4
        rs.append(px[o]); gs.append(px[o + 1]); bs.append(px[o + 2])
      }
      for x in stride(from: Int(ring.minX), to: Int(ring.maxX), by: step) {
        for y in [Int(ring.minY), Int(ring.maxY) - 1] where y < Int(rect.minY) || y >= Int(rect.maxY) { sample(x, y) }
      }
      for y in stride(from: Int(ring.minY), to: Int(ring.maxY), by: step) {
        for x in [Int(ring.minX), Int(ring.maxX) - 1] where x < Int(rect.minX) || x >= Int(rect.maxX) { sample(x, y) }
      }
      func median(_ v: [UInt8]) -> CGFloat { v.isEmpty ? 0.5 : CGFloat(v.sorted()[v.count / 2]) / 255 }
      return (rect, CGColor(red: median(rs), green: median(gs), blue: median(bs), alpha: 1))
    }
    for (rect, color) in fills {
      ctx.setFillColor(color)
      ctx.fill(CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY, width: rect.width, height: rect.height))
    }
    return ctx.makeImage()
  }

  /// Fit an image to Jev's limits (each side 280...1568 px): scaled down so the long side fits,
  /// up so the short side does, and padded with white at the right or bottom when the shape is
  /// too long for both. Returns the image and the scale, so fractions of the returned image map
  /// back to the input as `fraction * size / scale`.
  public static func fitForJev(_ image: CGImage, minSide: Int = 280, maxSide: Int = 1568) -> (image: CGImage, scale: CGFloat)? {
    let iw = CGFloat(image.width), ih = CGFloat(image.height)
    var scale = min(1, CGFloat(maxSide) / max(iw, ih))
    if min(iw, ih) * scale < CGFloat(minSide) { scale = min(CGFloat(maxSide) / max(iw, ih), CGFloat(minSide) / min(iw, ih)) }
    let cw = Int((iw * scale).rounded()), ch = Int((ih * scale).rounded())
    let w = max(minSide, cw), h = max(minSide, ch)
    guard let ctx = rgbContext(w, h) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: h - ch, width: cw, height: ch))
    guard let out = ctx.makeImage() else { return nil }
    return (out, scale)
  }

  public static func jpegDataURL(_ image: CGImage, quality: Double = 0.75) -> String? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return "data:image/jpeg;base64,\((data as Data).base64EncodedString())"
  }

  public static func load(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
  }

  static func rgbContext(_ w: Int, _ h: Int) -> CGContext? {
    CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }
}
