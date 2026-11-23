// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

public enum PinImageTransform {
  public static func apply(_ image: CGImage, quarterTurns: Int, mirrored: Bool) throws -> CGImage {
    let turns = ((quarterTurns % 4) + 4) % 4
    if turns == 0 && !mirrored { return image }
    let width = turns % 2 == 0 ? image.width : image.height
    let height = turns % 2 == 0 ? image.height : image.width
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ImageError.renderFailed }
    context.interpolationQuality = .none
    context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
    if mirrored { context.scaleBy(x: -1, y: 1) }
    context.rotate(by: -CGFloat(turns) * .pi / 2)
    context.draw(
      image,
      in: CGRect(
        x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
        width: CGFloat(image.width), height: CGFloat(image.height)))
    guard let output = context.makeImage() else { throw ImageError.renderFailed }
    return output
  }
}
