// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import CRapidOCR
import CoreGraphics
import FlameshoterCore
import Foundation

/// One lazily loaded Small detector and Small recognizer, used serially off the main actor.
actor PaddleTextRecognition {
  static let shared = PaddleTextRecognition()
  private var engine: OpaquePointer?

  deinit {
    if let engine { rpocr_destroy(engine) }
  }

  private func loadEngine() throws -> OpaquePointer {
    if let engine { return engine }
    let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
    guard let directory = bundle.url(forResource: "OCRModels", withExtension: nil) else {
      throw CocoaError(.fileNoSuchFile)
    }
    var options = rpocr_options()
    rpocr_options_init_ex(&options, MemoryLayout<rpocr_options>.size)
    options.model_type = RPOCR_MODEL_PPOCR
    options.backend = RPOCR_BACKEND_METAL
    options.use_cls = 0
    options.det_limit_type = 0
    options.det_limit_side_len = 1600
    options.det_mean = (0.5, 0.5, 0.5)
    options.det_std = (0.5, 0.5, 0.5)
    options.det_box_threshold = 0.5
    options.det_threshold = 0.3
    options.det_unclip_ratio = 1.6
    options.det_use_dilation = 1
    options.rec_batch_size = 6
    guard
      let handle = rpocr_create(
        directory.appendingPathComponent("PP-OCRv6_det_small.onnx").path,
        directory.appendingPathComponent("PP-OCRv6_rec_small.onnx").path,
        directory.appendingPathComponent("ppocrv6_dict.txt").path, &options)
    else { throw Self.engineError() }
    engine = handle
    return handle
  }

  func transcript(_ image: CGImage) throws -> String {
    try Task.checkCancellation()
    let handle = try loadEngine()
    // Preserve Retina text for line recognition while bounding detector and bitmap costs separately.
    let scale = min(1, 2560 / Double(max(image.width, image.height)))
    let scaledWidth = max(1, Int((Double(image.width) * scale).rounded()))
    let scaledHeight = max(1, Int((Double(image.height) * scale).rounded()))
    let width = max(32, scaledWidth)
    // A margin keeps narrow single-line selections large enough for detection.
    let height = max(32, scaledHeight, scaledWidth / 8)
    var bytes = Data(count: width * height * 3)
    return try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> String in
      var rgb = vImage_Buffer(
        data: buffer.baseAddress, height: vImagePixelCount(height),
        width: vImagePixelCount(width), rowBytes: width * 3)
      let rect = CGRect(
        x: (width - scaledWidth) / 2, y: (height - scaledHeight) / 2,
        width: scaledWidth, height: scaledHeight)
      try Self.fillRGB(image, in: rect, buffer: &rgb)
      var input = rpocr_image(
        width: Int32(width), height: Int32(height),
        rgb: buffer.bindMemory(to: UInt8.self).baseAddress)
      var result = rpocr_result()
      defer { rpocr_result_free(&result) }
      try Task.checkCancellation()
      guard rpocr_recognize(handle, &input, &result) == RPOCR_OK else { throw Self.engineError() }
      try Task.checkCancellation()
      return UnsafeBufferPointer(start: result.items, count: result.count).compactMap { line in
        guard line.confidence >= 0.5, let text = line.text else { return nil as String? }
        return String(cString: text)
      }.joined(separator: "\n")
    }
  }

  private static func fillRGB(_ image: CGImage, in rect: CGRect, buffer: inout vImage_Buffer) throws
  {
    let width = Int(buffer.width)
    let height = Int(buffer.height)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
      let pixels = context.data
    else { throw ImageError.renderFailed }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    var rgba = vImage_Buffer(
      data: pixels, height: buffer.height, width: buffer.width,
      rowBytes: context.bytesPerRow)
    let error = withExtendedLifetime(context) {
      vImageConvert_RGBA8888toRGB888(&rgba, &buffer, vImage_Flags(kvImageNoFlags))
    }
    guard error == kvImageNoError else { throw ImageError.renderFailed }
  }

  private static func engineError() -> NSError {
    NSError(
      domain: "PP-OCRv6 Small", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "PP-OCRv6 Small: " + String(cString: rpocr_last_error())
      ])
  }
}
