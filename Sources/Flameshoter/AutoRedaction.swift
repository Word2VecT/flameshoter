// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import Vision

struct RedactionOptions: Sendable {
  var emails = true
  var phones = true
  var addresses = true
  var faces = true
  var credentials = true
}

enum AutoRedaction {
  private static func expressions(_ patterns: String...) -> [NSRegularExpression] {
    patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
  }
  private static let emails = expressions(
    #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#)
  private static let phones = expressions(
    #"(?<![\w.])(?:\+\d{1,3}[\s-]?)?(?:\(?\d{2,4}\)?[\s-]?)?\d{3,4}[\s-]?\d{4}(?![\w.])"#)
  private static let addresses = expressions(
    #"\b(?:https?://|www\.)[^\s<>]+"#,
    #"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])"#,
    #"(?<!\w)(?:[a-f0-9]{1,4}:){2,}[a-f0-9:]{0,39}(?!\w)"#)
  private static let credentials = expressions(
    #"\b(?:bearer\s+)[A-Z0-9._~+/=\-]+"#,
    #"\b(?:password|passwd|token|secret|api[_ -]?key)\s*[:=]\s*[^\s,;]+"#,
    #"(?<!\w)(?:sk-[A-Z0-9_\-]{16,}|eyJ[A-Z0-9_\-]+\.[A-Z0-9_\-]+\.[A-Z0-9_\-]+)(?!\w)"#)

  // Match text first, then ask Vision for its exact character bounding box.
  static func ranges(in text: String, options: RedactionOptions) -> [NSRange] {
    let whole = NSRange(text.startIndex..<text.endIndex, in: text)
    var matches: [NSRange] = []
    func collect(_ expressions: [NSRegularExpression]) {
      for expression in expressions {
        matches.append(contentsOf: expression.matches(in: text, range: whole).map(\.range))
      }
    }
    if options.emails { collect(emails) }
    if options.phones { collect(phones) }
    if options.addresses { collect(addresses) }
    if options.credentials { collect(credentials) }
    matches.sort { $0.location < $1.location }
    var merged: [NSRange] = []
    for range in matches {
      if let last = merged.last, NSMaxRange(last) >= range.location {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  static func regions(_ image: CGImage, options: RedactionOptions) async throws -> [CGRect] {
    try await Task.detached(priority: .userInitiated) {
      let text = VNRecognizeTextRequest()
      text.recognitionLevel = .accurate
      text.usesLanguageCorrection = false
      let supported = try text.supportedRecognitionLanguages()
      text.recognitionLanguages = ["zh-Hans", "en-US"].filter { supported.contains($0) }
      let faces = VNDetectFaceRectanglesRequest()
      try VNImageRequestHandler(cgImage: image, orientation: .up).perform(
        options.faces ? [text, faces] : [text])
      var regions: [CGRect] = []
      for line in text.results ?? [] {
        guard let candidate = line.topCandidates(1).first else { continue }
        for match in ranges(in: candidate.string, options: options) {
          guard let range = Range(match, in: candidate.string) else { continue }
          let box = try candidate.boundingBox(for: range)?.boundingBox ?? line.boundingBox
          regions.append(box)
        }
      }
      if options.faces { regions += (faces.results ?? []).map(\.boundingBox) }
      return regions
    }.value
  }

  static func annotations(regions: [CGRect], selection: CGRect, scale: CGFloat) -> [Annotation] {
    regions.compactMap { normalized in
      let rect = CGRect(
        x: selection.minX + normalized.minX * selection.width,
        y: selection.minY + (1 - normalized.maxY) * selection.height,
        width: normalized.width * selection.width, height: normalized.height * selection.height
      )
      .insetBy(dx: -3 / scale, dy: -3 / scale).intersection(selection)
      guard !rect.isEmpty, !rect.isNull else { return nil }
      var annotation = Annotation(
        tool: .pixelate,
        points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], width: 12)
      annotation.traditionalPixelation = false
      return annotation
    }
  }

  @MainActor static func chooseOptions() -> RedactionOptions? {
    let alert = NSAlert()
    alert.messageText = localized("Automatically redact sensitive information", "自动遮挡敏感信息")
    alert.informativeText = localized(
      "Recognition runs on this Mac. Review the resulting masks before sharing; recognition can miss information. Each mask remains editable.",
      "在本机识别。完成后请检查遮挡区域，识别可能遗漏信息。每处遮挡都可修改或撤销。")
    alert.addButton(withTitle: localized("Recognize and redact", "识别并遮挡"))
    alert.addButton(withTitle: localized("Cancel", "取消"))
    let email = ActionCheck(localized("Email addresses", "邮箱"), on: true) { _ in }
    let phone = ActionCheck(localized("Phone numbers", "电话号码"), on: true) { _ in }
    let address = ActionCheck(localized("URLs and IP addresses", "网址和 IP 地址"), on: true) { _ in }
    let face = ActionCheck(localized("Faces", "人脸"), on: true) { _ in }
    let credential = ActionCheck(
      localized("Passwords, tokens and API keys", "密码、令牌和 API 密钥"), on: true
    ) { _ in }
    let content = stack([email, phone, address, face, credential])
    content.frame = CGRect(x: 0, y: 0, width: 320, height: 140)
    alert.accessoryView = content
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return RedactionOptions(
      emails: email.state == .on, phones: phone.state == .on,
      addresses: address.state == .on, faces: face.state == .on,
      credentials: credential.state == .on)
  }
}
