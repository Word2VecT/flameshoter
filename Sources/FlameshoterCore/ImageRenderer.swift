// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum ImageError: LocalizedError {
  case emptySelection, renderFailed, unsupportedFormat, encodeFailed
  public var errorDescription: String? {
    switch self {
    case .emptySelection: return "Select a capture region first."
    case .renderFailed: return "Unable to render this capture."
    case .unsupportedFormat: return "This image format is not supported."
    case .encodeFailed: return "Unable to encode the image."
    }
  }
}

@MainActor public enum ImageRenderer {
  private static let filters = CIContext(options: [.cacheIntermediates: false])
  public static func render(_ document: CaptureDocument, includeSelection: Bool = true) throws
    -> CGImage
  {
    let pixelRect =
      includeSelection
      ? document.pixelSelection
      : CGRect(x: 0, y: 0, width: document.image.width, height: document.image.height)
    guard !pixelRect.isNull, !pixelRect.isEmpty, let crop = document.image.cropping(to: pixelRect)
    else { throw ImageError.emptySelection }
    // The unannotated path returns a pixel crop directly: no material, scaling or color conversion.
    guard !document.annotations.isEmpty else { return crop }
    let space = document.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard
      let context = CGContext(
        data: nil, width: document.image.width, height: document.image.height, bitsPerComponent: 8,
        bytesPerRow: document.image.width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ImageError.renderFailed }
    context.interpolationQuality = .none
    context.draw(
      document.image,
      in: CGRect(x: 0, y: 0, width: document.image.width, height: document.image.height))
    context.translateBy(x: 0, y: CGFloat(document.image.height))
    context.scaleBy(x: document.scale, y: -document.scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    for annotation in document.annotations {
      let source =
        [.pixelate, .invert].contains(annotation.tool)
        ? context.makeImage() ?? document.image : document.image
      draw(annotation, in: context, source: source, scale: document.scale)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage()?.cropping(to: pixelRect) else {
      throw ImageError.renderFailed
    }
    return image
  }
  public static func draw(
    _ annotation: Annotation, in context: CGContext, source: CGImage, scale: CGFloat
  ) {
    let a = annotation
    let r = a.bounds
    guard let first = a.points.first else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.setStrokeColor(a.color.cgColor)
    context.setFillColor(a.color.cgColor)
    context.setLineWidth(a.width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setShouldAntialias(true)
    switch a.tool {
    case .pencil, .marker, .line:
      if a.tool == .marker { context.setAlpha(0.3) }
      context.beginPath()
      context.move(to: first)
      if a.points.count == 1 {
        context.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
      } else {
        for point in a.points.dropFirst() { context.addLine(to: point) }
      }
      context.strokePath()
    case .arrow:
      guard let last = a.points.last else { return }
      let start = a.reverseArrow ? last : first
      let end = a.reverseArrow ? first : last
      var tangent = start
      context.beginPath()
      context.move(to: start)
      if a.curvedArrow {
        let control = CGPoint(
          x: (start.x + end.x) / 2 - (end.y - start.y) * 0.2,
          y: (start.y + end.y) / 2 + (end.x - start.x) * 0.2)
        context.addQuadCurve(to: end, control: control)
        tangent = control
      } else {
        context.addLine(to: end)
      }
      context.strokePath()
      let angle = atan2(end.y - tangent.y, end.x - tangent.x)
      let length = max(10, a.width * 3.5)
      context.beginPath()
      context.move(to: end)
      context.addLine(
        to: CGPoint(x: end.x - length * cos(angle - 0.45), y: end.y - length * sin(angle - 0.45)))
      context.addLine(
        to: CGPoint(x: end.x - length * cos(angle + 0.45), y: end.y - length * sin(angle + 0.45)))
      context.closePath()
      context.fillPath()
    case .rectangle, .ellipse:
      if a.tool == .rectangle { context.addRect(r) } else { context.addEllipse(in: r) }
      context.drawPath(using: a.filled ? .fillStroke : .stroke)
    case .text:
      let base =
        a.font.isEmpty
        ? NSFont.systemFont(ofSize: a.fontSize)
        : NSFont(name: a.font, size: a.fontSize) ?? NSFontManager.shared.font(
          withFamily: a.font, traits: [], weight: 5, size: a.fontSize)
          ?? .systemFont(ofSize: a.fontSize)
      var traits: NSFontTraitMask = []
      if a.bold { traits.insert(.boldFontMask) }
      if a.italic { traits.insert(.italicFontMask) }
      let font = NSFontManager.shared.convert(base, toHaveTrait: traits)
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = a.alignment == 1 ? .center : a.alignment == 2 ? .right : .left
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: a.color.color, .paragraphStyle: paragraph,
        .underlineStyle: a.underline ? NSUnderlineStyle.single.rawValue : 0,
        .strikethroughStyle: a.strike ? NSUnderlineStyle.single.rawValue : 0,
      ]
      (a.text as NSString).draw(in: r, withAttributes: attributes)
    case .counter:
      context.setLineWidth(max(1, a.width / 18))
      context.addEllipse(in: r)
      if a.outlinedCounter {
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.drawPath(using: .fillStroke)
      } else {
        context.fillPath()
      }
      let font = NSFont.monospacedDigitSystemFont(
        ofSize: max(10, a.width * 0.55), weight: .semibold)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: a.outlinedCounter ? a.color.color : NSColor.white,
      ]
      let number = String(a.number) as NSString
      let size = number.size(withAttributes: attributes)
      number.draw(
        at: CGPoint(x: first.x - size.width / 2, y: first.y - size.height / 2),
        withAttributes: attributes)
    case .pixelate:
      if a.traditionalPixelation {
        drawFilter(
          "CIPixellate", rect: r, width: a.width, context: context, source: source, scale: scale)
      } else {
        redact(rect: r, block: max(4, a.width), context: context, source: source, scale: scale)
      }
    case .invert:
      drawFilter(
        "CIColorInvert", rect: r, width: a.width, context: context, source: source, scale: scale)
    default: break
    }
  }
  private static func drawFilter(
    _ name: String, rect: CGRect, width: Double, context: CGContext, source: CGImage, scale: CGFloat
  ) {
    let pixel = CGRect(
      x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
      height: rect.height * scale
    ).integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
    guard !pixel.isNull, !pixel.isEmpty, let region = source.cropping(to: pixel) else { return }
    let input = CIImage(cgImage: region)
    let parameters: [String: Any] =
      name == "CIPixellate" ? [kCIInputScaleKey: max(2, width * scale)] : [:]
    let output = input.applyingFilter(name, parameters: parameters)
    guard let image = filters.createCGImage(output, from: input.extent) else { return }
    drawUpright(image, in: rect, context: context)
  }
  private static func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
  }
  private static func redact(
    rect: CGRect, block: CGFloat, context: CGContext, source: CGImage, scale: CGFloat
  ) {
    let w = source.width
    let h = source.height
    guard
      let pixels = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    pixels.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = pixels.data?.assumingMemoryBound(to: UInt8.self) else { return }
    let r = CGRect(
      x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
      height: rect.height * scale
    ).integral
    var fringe: [CGColor] = []
    func sample(_ x: Int, _ y: Int) {
      guard x >= 0, y >= 0, x < w, y < h else { return }
      let n = y * w * 4 + x * 4
      fringe.append(
        CGColor(
          srgbRed: CGFloat(data[n]) / 255, green: CGFloat(data[n + 1]) / 255,
          blue: CGFloat(data[n + 2]) / 255, alpha: 1))
    }
    for x in stride(from: Int(r.minX), to: Int(r.maxX), by: max(1, Int(block * scale))) {
      sample(x, Int(r.minY) - 1)
      sample(x, Int(r.maxY))
    }
    for y in stride(from: Int(r.minY), to: Int(r.maxY), by: max(1, Int(block * scale))) {
      sample(Int(r.minX) - 1, y)
      sample(Int(r.maxX), y)
    }
    if fringe.isEmpty { fringe = [CGColor(gray: 0, alpha: 1)] }
    var index = 0
    context.saveGState()
    context.clip(to: rect)
    context.setShouldAntialias(false)
    for y in stride(from: rect.minY, to: rect.maxY, by: block) {
      for x in stride(from: rect.minX, to: rect.maxX, by: block) {
        context.setFillColor(fringe[(index * 17 + 3) % fringe.count])
        index += 1
        context.fill(CGRect(x: x, y: y, width: block, height: block))
      }
    }
    context.restoreGState()
  }
  public static func data(_ image: CGImage, format: String = "png", quality: Int = 75) throws
    -> Data
  {
    let type: UTType
    switch format.lowercased() {
    case "png": type = .png
    case "jpg", "jpeg": type = .jpeg
    case "tif", "tiff": type = .tiff
    case "bmp": type = .bmp
    case "webp": type = .webP
    default: throw ImageError.unsupportedFormat
    }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
    else { throw ImageError.unsupportedFormat }
    CGImageDestinationAddImage(
      destination, image,
      [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ImageError.encodeFailed }
    return data as Data
  }
  public static func copy(_ image: CGImage, jpeg: Bool = false, quality: Int = 75) throws {
    let data = try self.data(image, format: jpeg ? "jpeg" : "png", quality: quality)
    let board = NSPasteboard.general
    board.clearContents()
    board.setData(data, forType: jpeg ? NSPasteboard.PasteboardType(UTType.jpeg.identifier) : .png)
  }
}

public enum FilenamePattern {
  public static func render(_ pattern: String, date: Date = Date(), timeZone: TimeZone = .current)
    -> String
  {
    let formats: [Character: String] = [
      "F": "yyyy-MM-dd", "Y": "yyyy", "y": "yy", "m": "MM", "d": "dd", "H": "HH", "M": "mm",
      "S": "ss", "T": "HH-mm-ss", "R": "HH-mm", "a": "EEE", "A": "EEEE", "b": "MMM", "B": "MMMM",
      "j": "DDD", "V": "ww", "u": "e", "z": "Z", "Z": "zzz",
    ]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    var output = ""
    var escaped = false
    for character in pattern.isEmpty ? "%F_%H-%M-%S" : pattern {
      if escaped {
        if let format = formats[character] {
          formatter.dateFormat = format
          output += formatter.string(from: date)
        } else if character == "s" {
          output += String(Int(date.timeIntervalSince1970))
        } else {
          output.append(character)
        }
        escaped = false
      } else if character == "%" {
        escaped = true
      } else {
        output.append(character)
      }
    }
    return output.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")
  }
}
