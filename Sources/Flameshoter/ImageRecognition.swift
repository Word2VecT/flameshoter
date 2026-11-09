// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Vision
import VisionKit

enum RecognitionKind {
  case text, qrCode
}

enum ImageRecognition {
  static func text(_ image: CGImage) async throws -> ImageAnalysis {
    let supported = ImageAnalyzer.supportedTextRecognitionLanguages
    let preferred = Locale.preferredLanguages.compactMap { language in
      supported.first { language == $0 || language.hasPrefix($0 + "-") }
        ?? supported.first { $0.split(separator: "-").first == language.split(separator: "-").first }
    }
    var configuration = ImageAnalyzer.Configuration(.text)
    for language in preferred + ["zh-Hans", "en-US"] where supported.contains(language) {
      if !configuration.locales.contains(language) { configuration.locales.append(language) }
    }
    return try await ImageAnalyzer().analyze(image, orientation: .up, configuration: configuration)
  }

  static func qrCodes(_ image: CGImage) async throws -> [String] {
    try await Task.detached(priority: .userInitiated) {
      let request = VNDetectBarcodesRequest()
      request.symbologies = [.qr]
      try VNImageRequestHandler(cgImage: image).perform([request])
      return (request.results ?? []).compactMap(\.payloadStringValue)
    }.value
  }
}

@MainActor final class RecognitionWindowController: NSWindowController, NSWindowDelegate,
  ImageAnalysisOverlayViewDelegate, NSTextViewDelegate
{
  private let image: CGImage
  private let kind: RecognitionKind
  private let imageView = NSImageView()
  private let overlay = ImageAnalysisOverlayView()
  private let textView = NSTextView()
  private let status = NSTextField(labelWithString: "")
  private let copyButton: ActionButton
  var onClose: ((RecognitionWindowController) -> Void)?

  init(image: CGImage, kind: RecognitionKind) {
    self.image = image
    self.kind = kind
    copyButton = ActionButton(localized("Copy text", "复制文本"), action: {})
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 500),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = kind == .text
      ? localized("Text recognition", "文字识别") : localized("QR code recognition", "二维码识别")
    window.minSize = NSSize(width: 560, height: 320)
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    copyButton.invoke = { [weak self] in self?.copyText() }
    copyButton.isEnabled = false
    buildView()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func buildView() {
    guard let window else { return }
    let root = NSView()
    window.contentView = root
    let split = NSSplitView()
    split.isVertical = true
    split.dividerStyle = .thin
    split.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(split)
    let imageContainer = NSView()
    imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageContainer.addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
    ])
    imageView.setAccessibilityLabel(localized("Original image", "原始图像"))
    overlay.frame = imageView.bounds
    overlay.autoresizingMask = [.width, .height]
    overlay.trackingImageView = imageView
    overlay.preferredInteractionTypes = .textSelection
    overlay.delegate = self
    imageView.addSubview(overlay)
    split.addArrangedSubview(imageContainer)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = .systemFont(ofSize: 14)
    textView.textContainerInset = NSSize(width: 10, height: 10)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.containerSize = NSSize(
      width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.delegate = self
    textView.setAccessibilityLabel(localized("Recognition result", "识别结果"))
    scroll.documentView = textView
    split.addArrangedSubview(scroll)
    imageContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    status.stringValue = localized("Recognizing on this Mac…", "正在本机识别…")
    status.textColor = .secondaryLabelColor
    status.translatesAutoresizingMaskIntoConstraints = false
    copyButton.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(status)
    root.addSubview(copyButton)
    NSLayoutConstraint.activate([
      split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      split.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
      split.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -12),
      copyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
      status.leadingAnchor.constraint(equalTo: split.leadingAnchor),
      status.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
      status.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -12),
    ])
    window.layoutIfNeeded()
    split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
  }

  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
    Task { [weak self] in
      guard let self else { return }
      do {
        switch self.kind {
        case .text:
          let analysis = try await ImageRecognition.text(self.image)
          self.overlay.analysis = analysis
          self.showResult(analysis.transcript)
        case .qrCode:
          self.showResult(try await ImageRecognition.qrCodes(self.image).joined(separator: "\n"))
        }
      } catch {
        self.status.stringValue = localized("Recognition failed", "识别失败") + ": " + errorMessage(error)
      }
    }
  }

  private func showResult(_ text: String) {
    textView.string = text
    textView.isEditable = true
    copyButton.isEnabled = !text.isEmpty
    status.stringValue = text.isEmpty
      ? (kind == .text ? localized("No text found", "未识别到文字")
        : localized("No QR code found", "未识别到二维码"))
      : localized("Recognition complete", "识别完成")
  }

  private func copyText() {
    let range = textView.selectedRange()
    let selected = range.length > 0 ? (textView.string as NSString).substring(with: range) : ""
    let value = !selected.isEmpty
      ? selected : (!overlay.selectedText.isEmpty ? overlay.selectedText : textView.string)
    guard !value.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  func overlayView(
    _ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
    forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes
  ) -> Bool {
    overlayView.analysisHasText(at: point) || overlayView.hasInteractiveItem(at: point)
      || overlayView.hasActiveTextSelection
  }
  func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
    if overlayView.hasActiveTextSelection { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
  }
  func textViewDidChangeSelection(_ notification: Notification) {
    if textView.selectedRange().length > 0 { overlay.resetSelection() }
  }
  func textDidChange(_ notification: Notification) { copyButton.isEnabled = !textView.string.isEmpty }
  func windowWillClose(_ notification: Notification) { onClose?(self) }
}
