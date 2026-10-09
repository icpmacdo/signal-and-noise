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
