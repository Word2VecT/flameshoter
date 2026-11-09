// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

struct ScreenColor: Equatable {
  let red: Int
  let green: Int
  let blue: Int

  static func parse(_ value: String) -> ScreenColor? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
    if (hex.count == 3 && text.hasPrefix("#")) || hex.count == 6,
      hex.allSatisfy({ $0.isHexDigit })
    {
      let digits = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
      guard let number = Int(digits, radix: 16) else { return nil }
      return ScreenColor(red: (number >> 16) & 255, green: (number >> 8) & 255, blue: number & 255)
    }
    guard text.hasPrefix("rgb("), text.hasSuffix(")") else { return nil }
    let parts = text.dropFirst(4).dropLast().split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    let values = parts.compactMap {
      Int($0.trimmingCharacters(in: .whitespaces))
    }
    guard values.count == 3, values.allSatisfy({ (0...255).contains($0) }) else { return nil }
    return ScreenColor(red: values[0], green: values[1], blue: values[2])
  }

  var color: NSColor {
    NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: 1)
  }

  enum Format: Int, CaseIterable {
    case hashHex, rgb, bgr, hex, hsv, hsl
    var title: String {
      switch self {
      case .hashHex: return "#HEX"
      case .rgb: return "RGB"
      case .bgr: return "BGR"
      case .hex: return "HEX"
      case .hsv: return "HSV"
      case .hsl: return "HSL"
      }
    }
  }

  static func sample(_ image: CGImage, point: CGPoint, scale: CGFloat) -> ScreenColor? {
    let x = Int((point.x * scale).rounded(.down))
    let y = Int((point.y * scale).rounded(.down))
    guard x >= 0, y >= 0, x < image.width, y < image.height,
      let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
    else { return nil }
    var bytes = [UInt8](repeating: 0, count: 4)
    let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      return true
    }
    guard success else { return nil }
    let alpha = Int(bytes[3])
    func component(_ value: UInt8) -> Int {
      alpha == 0 ? 0 : min(255, (Int(value) * 255 + alpha / 2) / alpha)
    }
    return ScreenColor(red: component(bytes[0]), green: component(bytes[1]), blue: component(bytes[2]))
  }

  static func neighborhood(_ image: CGImage, point: CGPoint, scale: CGFloat) -> CGImage? {
    let side = 17
    let area = CGRect(
      x: Int((point.x * scale).rounded(.down)) - side / 2,
      y: Int((point.y * scale).rounded(.down)) - side / 2, width: side, height: side)
    let clipped = area.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !clipped.isEmpty, let part = image.cropping(to: clipped) else { return nil }
    if clipped == area { return part }
    let colorSpace = image.colorSpace?.model == .rgb
      ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(part, in: CGRect(
      x: clipped.minX - area.minX,
      y: CGFloat(side) - (clipped.minY - area.minY) - clipped.height,
      width: clipped.width, height: clipped.height))
    return context.makeImage()
  }

  func string(_ format: Format) -> String {
    switch format {
    case .hashHex: return String(format: "#%02x%02x%02x", red, green, blue)
    case .hex: return String(format: "%02x%02x%02x", red, green, blue)
    case .rgb: return "rgb(\(red), \(green), \(blue))"
    case .bgr: return "bgr(\(blue), \(green), \(red))"
    case .hsv, .hsl:
      let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
      let maximum = max(r, g, b), minimum = min(r, g, b), delta = maximum - minimum
      let hue: Double
      if delta == 0 { hue = 0 }
      else if maximum == r { hue = (60 * (g - b) / delta + 360).truncatingRemainder(dividingBy: 360) }
      else if maximum == g { hue = 60 * ((b - r) / delta + 2) }
      else { hue = 60 * ((r - g) / delta + 4) }
      let lightness = (maximum + minimum) / 2
      let saturation = format == .hsv
        ? (maximum == 0 ? 0 : delta / maximum)
        : (delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1)))
      let value = format == .hsv ? maximum : lightness
      return "\(format.title.lowercased())(\(Int(hue.rounded()) % 360), \(Int((saturation * 100).rounded()))%, \(Int((value * 100).rounded()))%)"
    }
  }
}
