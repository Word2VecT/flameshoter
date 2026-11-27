// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Vision
import VisionKit

enum RecognitionKind {
  case text, qrCode, document
}

struct RecognizedTextLine: Equatable, Sendable {
  let text: String
  // Vision's normalized image coordinates have their origin at the lower left.
  let bounds: CGRect
}

enum ImageRecognition {
  struct Barcode: Equatable, Sendable {
    let payload: String
    let symbology: String
  }
  static func barcodes(_ image: CGImage) async throws -> [Barcode] {
    try await Task.detached(priority: .userInitiated) {
      let request = VNDetectBarcodesRequest()
      request.symbologies = try request.supportedSymbologies()
      try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
      return (request.results ?? []).compactMap { observation in
        observation.payloadStringValue.map {
          Barcode(payload: $0, symbology: observation.symbology.rawValue)
        }
      }
    }.value
  }
  static func lines(_ image: CGImage, language: String? = nil) async throws -> [RecognizedTextLine]
  {
    try await Task.detached(priority: .userInitiated) {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      let supported = try request.supportedRecognitionLanguages()
      let requested =
        language.map { [$0, "en-US"] }
        ?? Array(Locale.preferredLanguages.prefix(2)) + ["zh-Hans", "en-US"]
      var chosen: [String] = []
      for raw in requested {
        let identifier = raw == "zh-TW" || raw == "zh-HK" ? "zh-Hant" : raw
        let match =
          supported.first { $0.caseInsensitiveCompare(identifier) == .orderedSame }
          ?? supported.first {
            $0.split(separator: "-").first == identifier.split(separator: "-").first
          }
        if let match, !chosen.contains(match) { chosen.append(match) }
      }
      if !chosen.isEmpty { request.recognitionLanguages = chosen }
      try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
      return (request.results ?? []).compactMap { observation in
        observation.topCandidates(1).first.map {
          RecognizedTextLine(text: $0.string, bounds: observation.boundingBox)
        }
      }
    }.value
  }
  static func text(_ image: CGImage) async throws -> ImageAnalysis {
    let supported = ImageAnalyzer.supportedTextRecognitionLanguages
    let preferred = Locale.preferredLanguages.compactMap { language in
      supported.first { language == $0 || language.hasPrefix($0 + "-") }
        ?? supported.first {
          $0.split(separator: "-").first == language.split(separator: "-").first
        }
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

@MainActor
final class RecognitionWindowController: NSWindowController, NSWindowDelegate,
  ImageAnalysisOverlayViewDelegate, NSTextViewDelegate
{
  private let image: CGImage
  private let kind: RecognitionKind
  private let imageView = NSImageView()
  private let overlay = ImageAnalysisOverlayView()
  private let textView = NSTextView()
  private let status = NSTextField(labelWithString: "")
  private let copyButton: ActionButton
  private let saveButton = ActionButton(
    localized("Save document…", "保存文档…"), symbol: "square.and.arrow.down", action: {})
  private var recognitionTask: Task<Void, Never>?
  private var selectionTask: Task<Void, Never>?
  var onClose: ((RecognitionWindowController) -> Void)?

  init(image: CGImage, kind: RecognitionKind) {
    self.image = image
    self.kind = kind
    copyButton = ActionButton(localized("Copy text", "复制文本"), action: {})
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 500),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title =
      kind == .qrCode
      ? localized("QR / barcode recognition", "二维码 / 条码识别")
      : kind == .document
        ? localized("Document recognition", "文档识别") : localized("Text recognition", "文字识别")
    window.minSize = NSSize(width: 560, height: 320)
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    copyButton.invoke = { [weak self] in self?.copyText() }
    copyButton.isEnabled = false
    saveButton.isEnabled = false
    saveButton.invoke = { [weak self] in self?.saveDocument() }
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
    imageView.image = NSImage(
      cgImage: image, size: NSSize(width: image.width, height: image.height))
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
    if kind == .text {
      // VisionKit supplies the selectable original only when the reader uses that pane.
      overlay.addTrackingArea(NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self, userInfo: nil))
    }
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
    saveButton.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(saveButton)
    NSLayoutConstraint.activate([
      split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      split.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
      split.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -12),
      copyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
      status.leadingAnchor.constraint(equalTo: split.leadingAnchor),
      status.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
      saveButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
      saveButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
      status.trailingAnchor.constraint(lessThanOrEqualTo: saveButton.leadingAnchor, constant: -12),
    ])
    window.layoutIfNeeded()
    split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
  }

  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
    if NSWorkspace.shared.isVoiceOverEnabled { prepareImageSelection() }
    recognitionTask?.cancel()
    recognitionTask = Task { [weak self] in await self?.recognize() }
  }

  func recognize() async {
    do {
      switch kind {
      case .text:
        let transcript = try await PaddleTextRecognition.shared.transcript(image)
        guard !Task.isCancelled else { return }
        showResult(transcript)
      case .qrCode:
        let codes = try await ImageRecognition.barcodes(image)
        guard !Task.isCancelled else { return }
        showResult(codes.map(\.payload).joined(separator: "\n"))
        if !codes.isEmpty {
          status.stringValue = codes.map(\.symbology).joined(separator: ", ")
        }
      case .document:
        let text = try await DocumentRecognition.text(image)
        guard !Task.isCancelled else { return }
        showResult(text)
      }
    } catch {
      guard !Task.isCancelled else { return }
      status.stringValue =
        localized("Recognition failed", "识别失败") + ": " + errorMessage(error)
    }
  }

  override func mouseEntered(with event: NSEvent) {
    prepareImageSelection()
  }

  private func prepareImageSelection() {
    guard kind == .text, overlay.analysis == nil, selectionTask == nil else { return }
    selectionTask = Task { [weak self, image] in
      let analysis = try? await ImageRecognition.text(image)
      guard !Task.isCancelled else { return }
      self?.overlay.analysis = analysis
      self?.selectionTask = nil
    }
  }

  private func showResult(_ text: String) {
    textView.string = text
    textView.isEditable = true
    copyButton.isEnabled = !text.isEmpty
    saveButton.isEnabled = !text.isEmpty
    status.stringValue =
      text.isEmpty
      ? (kind != .qrCode
        ? localized("No text found", "未识别到文字")
        : localized("No QR code or barcode found", "未识别到二维码或条码"))
      : localized("Recognition complete", "识别完成")
  }

  func copyText(to pasteboard: NSPasteboard = .general) {
    let range = textView.selectedRange()
    let selected = range.length > 0 ? (textView.string as NSString).substring(with: range) : ""
    let value =
      !selected.isEmpty
      ? selected : (!overlay.selectedText.isEmpty ? overlay.selectedText : textView.string)
    guard !value.isEmpty else { return }
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
  }

  func overlayView(
    _ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
    forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes
  ) -> Bool {
    let reflected = CGPoint(x: point.x, y: overlayView.bounds.height - point.y)
    return overlayView.analysisHasText(at: point) || overlayView.analysisHasText(at: reflected)
      || overlayView.hasInteractiveItem(at: point) || overlayView.hasActiveTextSelection
  }
  func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
    if overlayView.hasActiveTextSelection {
      textView.setSelectedRange(NSRange(location: 0, length: 0))
    }
  }
  func textViewDidChangeSelection(_ notification: Notification) {
    if textView.selectedRange().length > 0 { overlay.resetSelection() }
  }
  private func saveDocument() {
    guard let window else { return }
    let panel = NSSavePanel()
    let formats = DocumentExport.Format.allCases
    let popup = ActionPopup(items: formats.map(\.label), selected: 0) { index in
      panel.allowedContentTypes = [formats[index].contentType]
      panel.nameFieldStringValue = "Flameshoter." + formats[index].rawValue
    }
    panel.allowedContentTypes = [formats[0].contentType]
    panel.nameFieldStringValue = "Flameshoter.docx"
    panel.accessoryView = popup
    panel.beginSheetModal(for: window) { [weak self] result in
      guard result == .OK, let self, let url = panel.url else { return }
      do {
        try DocumentExport.data(self.textView.string, format: formats[popup.indexOfSelectedItem])
          .write(to: url, options: .atomic)
        self.status.stringValue = localized("Saved", "已保存") + " · " + url.lastPathComponent
      } catch {
        self.status.stringValue =
          localized("Unable to save document", "无法保存文档") + ": " + errorMessage(error)
      }
    }
  }
  func textDidChange(_ notification: Notification) {
    copyButton.isEnabled = !textView.string.isEmpty
    saveButton.isEnabled = !textView.string.isEmpty
  }
  func windowWillClose(_ notification: Notification) {
    recognitionTask?.cancel()
    selectionTask?.cancel()
    selectionTask = nil
    onClose?(self)
  }
}
