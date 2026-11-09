// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import FlameshoterCore
import NaturalLanguage
import SwiftUI
import Translation

struct TranslationWork: Sendable {
  let id: UUID
  let lines: [String]
}

@MainActor final class TranslationCoordinator: ObservableObject {
  @Published var configuration: TranslationSession.Configuration?
  private(set) var pending: TranslationWork?
  var onResult: ((Result<[String], Error>) -> Void)?

  func start(lines: [String], source: String?, target: String) {
    pending = TranslationWork(id: UUID(), lines: lines)
    let sourceLanguage = source.map { Locale.Language(identifier: $0) }
    let targetLanguage = Locale.Language(identifier: target)
    if var current = configuration, current.source == sourceLanguage, current.target == targetLanguage {
      current.invalidate()
      configuration = current
    } else {
      configuration = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
    }
  }

  func finish(_ work: TranslationWork, result: Result<[String], Error>) {
    guard pending?.id == work.id else { return }
    pending = nil
    onResult?(result)
  }

  func cancel() {
    pending = nil
    configuration = nil
  }
}

@MainActor struct TranslationHost: View {
  @ObservedObject var coordinator: TranslationCoordinator
  var body: some View {
    let work = coordinator.pending
    return Color.clear.translationTask(coordinator.configuration) { session in
      guard let work, await MainActor.run(body: { coordinator.pending?.id == work.id }) else { return }
      do {
        let requests = work.lines.enumerated().map {
          TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let response = try await session.translations(from: requests)
        var translated = Array(repeating: "", count: work.lines.count)
        for item in response {
          guard let id = item.clientIdentifier.flatMap(Int.init), translated.indices.contains(id) else {
            throw TranslationDisplayError.incomplete
          }
          translated[id] = item.targetText
        }
        guard response.count == translated.count, translated.allSatisfy({ !$0.isEmpty }) else {
          throw TranslationDisplayError.incomplete
        }
        await MainActor.run { coordinator.finish(work, result: .success(translated)) }
      } catch {
        await MainActor.run { coordinator.finish(work, result: .failure(error)) }
      }
    }
  }
}

enum TranslationDisplayError: LocalizedError {
  case incomplete, renderFailed
  var errorDescription: String? {
    switch self {
    case .incomplete: return "The translation did not include every text line."
    case .renderFailed: return "The translated image could not be rendered."
    }
  }
}

@MainActor enum TranslationImageRenderer {
  struct Output {
    let image: CGImage
    let hasTruncatedText: Bool
  }
  static func render(_ image: CGImage, lines: [RecognizedTextLine], translated: [String]) throws -> Output {
    guard lines.count == translated.count else { throw TranslationDisplayError.incomplete }
    let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TranslationDisplayError.renderFailed }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let width = image.width, height = image.height
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    var truncated = false
    let boxes = lines.map { line in
      CGRect(x: line.bounds.minX * CGFloat(width), y: line.bounds.minY * CGFloat(height),
             width: line.bounds.width * CGFloat(width), height: line.bounds.height * CGFloat(height)).integral
    }
    for (index, value) in translated.enumerated() where !value.isEmpty {
      let box = boxes[index]
      let horizontal = max(3, box.height * 0.1)
      var below = max(4, box.height * 0.2)
      var above = below
      for (otherIndex, other) in boxes.enumerated() where otherIndex != index {
        guard min(box.maxX, other.maxX) > max(box.minX, other.minX) else { continue }
        if other.maxY <= box.minY { below = min(below, (box.minY - other.maxY) / 2) }
        if other.minY >= box.maxY { above = min(above, (other.minY - box.maxY) / 2) }
      }
      let rect = CGRect(x: box.minX - horizontal, y: box.minY - below,
                        width: box.width + horizontal * 2, height: box.height + below + above)
        .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
      guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }
      let samples = [
        CGPoint(x: rect.minX - 1, y: rect.minY - 1), CGPoint(x: rect.maxX, y: rect.minY - 1),
        CGPoint(x: rect.minX - 1, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
      ].map { point -> (CGFloat, CGFloat, CGFloat) in
        let x = max(0, min(width - 1, Int(point.x)))
        let y = max(0, min(height - 1, Int(point.y)))
        // Bitmap rows start at the top while Vision rectangles use a lower-left origin.
        let index = ((height - 1 - y) * width + x) * 4
        return (CGFloat(pixels[index]) / 255, CGFloat(pixels[index + 1]) / 255,
                CGFloat(pixels[index + 2]) / 255)
      }
      let red = samples.map(\.0).sorted()[samples.count / 2]
      let green = samples.map(\.1).sorted()[samples.count / 2]
      let blue = samples.map(\.2).sorted()[samples.count / 2]
      let background = CGColor(colorSpace: space, components: [red, green, blue, 1])!
      context.setFillColor(background)
      context.fill(rect)
      let foreground: NSColor = (red * 0.299 + green * 0.587 + blue * 0.114) < 0.5 ? .white : .black
      let text = value as NSString
      var size = max(6, rect.height * 0.75)
      var font = NSFont.systemFont(ofSize: size)
      let available = max(1, rect.width - 4)
      let measured = text.size(withAttributes: [.font: font]).width
      if measured > available {
        let fitted = size * available / measured
        if fitted < 6 { truncated = true }
        size = max(6, fitted)
        font = NSFont.systemFont(ofSize: size)
      }
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byTruncatingTail
      text.draw(in: rect.insetBy(dx: 2, dy: 1), withAttributes: [
        .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph,
      ])
    }
    guard let result = context.makeImage() else { throw TranslationDisplayError.renderFailed }
    return Output(image: result, hasTruncatedText: truncated)
  }
}

@MainActor final class TranslationWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  private let image: CGImage
  private let coordinator = TranslationCoordinator()
  private let imageView = NSImageView()
  private let sourceText = NSTextView()
  private let targetText = NSTextView()
  private let sourceLanguage = NSPopUpButton()
  private let targetLanguage = NSPopUpButton()
  private let imageMode = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
  private let status = NSTextField(labelWithString: "")
  private let translateButton = ActionButton("", action: {})
  private let recognizeButton = ActionButton("", action: {})
  private let copyButton = ActionButton("", action: {})
  private let saveImageButton = ActionButton("", action: {})
  private let copyImageButton = ActionButton("", action: {})
  private var languages: [Locale.Language] = []
  private var lines: [RecognizedTextLine] = []
  private var translatedImage: CGImage?
  private var updating = false
  private var translating = false
  private var recognized = false
  private var closed = false
  private var userSelectedTarget = false
  private var renderTask: Task<Void, Never>?
  private var recognitionID: UUID?
  var onClose: ((TranslationWindowController) -> Void)?

  init(image: CGImage) {
    self.image = image
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 920, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = localized("Translate screenshot", "截图翻译")
    window.minSize = NSSize(width: 660, height: 420)
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    coordinator.onResult = { [weak self] result in self?.finishTranslation(result) }
    buildView()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func buildView() {
    guard let window else { return }
    let root = NSView()
    window.contentView = root
    sourceLanguage.addItem(withTitle: localized("Detect language", "自动识别"))
    sourceLanguage.setAccessibilityLabel(localized("Source language", "原文语言"))
    targetLanguage.setAccessibilityLabel(localized("Target language", "译文语言"))
    sourceLanguage.target = self
    sourceLanguage.action = #selector(languageChanged(_:))
    targetLanguage.target = self
    targetLanguage.action = #selector(languageChanged(_:))
    sourceLanguage.widthAnchor.constraint(equalToConstant: 150).isActive = true
    targetLanguage.widthAnchor.constraint(equalToConstant: 150).isActive = true
    translateButton.title = localized("Translate", "翻译")
    translateButton.invoke = { [weak self] in self?.startTranslation() }
    translateButton.isEnabled = false
    recognizeButton.title = localized("Recognize again", "重新识别")
    recognizeButton.toolTip = localized("Recognize using the selected source language", "按所选原文语言重新识别")
    recognizeButton.invoke = { [weak self] in self?.recognizeAgain() }
    recognizeButton.isEnabled = false
    let header = stack([
      sourceLanguage, label("→"), targetLanguage, recognizeButton, translateButton, NSView(),
    ], vertical: false, spacing: 10)
    header.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(header)
    let split = NSSplitView()
    split.isVertical = true
    split.dividerStyle = .thin
    split.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(split)
    let imagePane = NSView()
    imagePane.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    imageView.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    imageView.setAccessibilityLabel(localized("Screenshot", "截图"))
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imagePane.addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: imagePane.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: imagePane.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: imagePane.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: imagePane.bottomAnchor),
    ])
    split.addArrangedSubview(imagePane)
    let textPane = NSView()
    textPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
    let sourceLabel = label(localized("Original text", "原文"))
    let resultLabel = label(localized("Translation", "译文"))
    let sourceScroll = makeTextView(sourceText, accessibility: localized("Original text", "原文"))
    let targetScroll = makeTextView(targetText, accessibility: localized("Translation", "译文"))
    for view in [sourceLabel, resultLabel, sourceScroll, targetScroll] {
      view.translatesAutoresizingMaskIntoConstraints = false
      textPane.addSubview(view)
    }
    NSLayoutConstraint.activate([
      sourceLabel.leadingAnchor.constraint(equalTo: textPane.leadingAnchor, constant: 12),
      sourceLabel.topAnchor.constraint(equalTo: textPane.topAnchor),
      sourceScroll.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
      sourceScroll.trailingAnchor.constraint(equalTo: textPane.trailingAnchor),
      sourceScroll.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 5),
      resultLabel.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
      resultLabel.topAnchor.constraint(equalTo: sourceScroll.bottomAnchor, constant: 10),
      targetScroll.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
      targetScroll.trailingAnchor.constraint(equalTo: textPane.trailingAnchor),
      targetScroll.topAnchor.constraint(equalTo: resultLabel.bottomAnchor, constant: 5),
      targetScroll.bottomAnchor.constraint(equalTo: textPane.bottomAnchor),
      sourceScroll.heightAnchor.constraint(equalTo: targetScroll.heightAnchor),
    ])
    split.addArrangedSubview(textPane)
    imageMode.segmentCount = 2
    imageMode.setLabel(localized("Original", "原图"), forSegment: 0)
    imageMode.setLabel(localized("Translation", "译图"), forSegment: 1)
    imageMode.selectedSegment = 0
    imageMode.setEnabled(false, forSegment: 1)
    imageMode.target = self
    imageMode.action = #selector(changeImageMode(_:))
    copyButton.title = localized("Copy translation", "复制译文")
    copyButton.invoke = { [weak self] in self?.copyTranslation() }
    copyButton.isEnabled = false
    saveImageButton.title = localized("Save translated image…", "保存译图…")
    saveImageButton.invoke = { [weak self] in self?.saveTranslatedImage() }
    saveImageButton.isEnabled = false
    copyImageButton.title = localized("Copy image", "复制译图")
    copyImageButton.invoke = { [weak self] in self?.copyTranslatedImage() }
    copyImageButton.isEnabled = false
    status.textColor = .secondaryLabelColor
    status.lineBreakMode = .byTruncatingTail
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    status.stringValue = localized("Recognizing on this Mac…", "正在本机识别…")
    let bottom = stack([imageMode, status, NSView(), copyButton, copyImageButton, saveImageButton], vertical: false, spacing: 10)
    bottom.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(bottom)
    let bridge = NSHostingView(rootView: TranslationHost(coordinator: coordinator))
    bridge.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(bridge)
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
      split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
      split.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
      bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
      bridge.widthAnchor.constraint(equalToConstant: 1), bridge.heightAnchor.constraint(equalToConstant: 1),
      bridge.trailingAnchor.constraint(equalTo: root.trailingAnchor), bridge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    window.layoutIfNeeded()
    split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
  }

  private func makeTextView(_ view: NSTextView, accessibility: String) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    view.isEditable = false
    view.font = .systemFont(ofSize: 14)
    view.textContainerInset = NSSize(width: 8, height: 8)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    view.delegate = self
    view.setAccessibilityLabel(accessibility)
    scroll.documentView = view
    return scroll
  }

  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
    Task { [weak self] in
      let supported = await LanguageAvailability().supportedLanguages
      guard let self, !self.closed else { return }
      self.installLanguages(supported)
      self.beginIfReady()
    }
    recognize(language: nil)
  }

  private func installLanguages(_ supported: [Locale.Language]) {
    let locale = Locale(identifier: Environment.shared.preferences.chinese ? "zh-Hans" : "en")
    languages = supported.sorted {
      (locale.localizedString(forIdentifier: $0.minimalIdentifier) ?? $0.minimalIdentifier)
        .localizedStandardCompare(locale.localizedString(forIdentifier: $1.minimalIdentifier) ?? $1.minimalIdentifier) == .orderedAscending
    }
    let titles = languages.map { locale.localizedString(forIdentifier: $0.minimalIdentifier) ?? $0.minimalIdentifier }
    sourceLanguage.removeAllItems()
    sourceLanguage.addItems(withTitles: [localized("Detect language", "自动识别")] + titles)
    targetLanguage.removeAllItems()
    targetLanguage.addItems(withTitles: titles)
    let desired = Environment.shared.preferences.chinese ? "zh" : "en"
    if let index = languages.firstIndex(where: { $0.minimalIdentifier == desired }) { targetLanguage.selectItem(at: index) }
    recognizeButton.isEnabled = recognized && !languages.isEmpty
    if languages.isEmpty { status.stringValue = localized("System translation is unavailable", "系统翻译不可用") }
  }

  private func recognizeAgain() {
    let original = lines.map(\.text).joined(separator: "\n")
    if sourceText.string != original && !sourceText.string.isEmpty {
      let alert = NSAlert()
      alert.messageText = localized("Replace edited text?", "替换已编辑的原文？")
      alert.informativeText = localized("Recognizing again replaces the current original text.", "重新识别会替换当前原文。")
      alert.addButton(withTitle: localized("Cancel", "取消"))
      alert.addButton(withTitle: localized("Recognize again", "重新识别"))
      guard alert.runModal() == .alertSecondButtonReturn else { return }
    }
    let index = sourceLanguage.indexOfSelectedItem - 1
    recognize(language: languages.indices.contains(index) ? languages[index].minimalIdentifier : nil)
  }

  private func recognize(language: String?) {
    let id = UUID()
    recognitionID = id
    recognized = false
    coordinator.cancel()
    translating = false
    recognizeButton.isEnabled = false
    translateButton.isEnabled = false
    copyButton.isEnabled = false
    copyImageButton.isEnabled = false
    saveImageButton.isEnabled = false
    imageMode.selectedSegment = 0
    imageMode.setEnabled(false, forSegment: 1)
    translatedImage = nil
    changeImageMode(nil)
    status.stringValue = localized("Recognizing on this Mac…", "正在本机识别…")
    Task { [weak self] in
      guard let self else { return }
      do {
        let found = try await ImageRecognition.lines(self.image, language: language)
        guard !self.closed, self.recognitionID == id else { return }
        self.lines = found
        self.updating = true
        self.sourceText.string = found.map(\.text).joined(separator: "\n")
        self.updating = false
        self.sourceText.isEditable = true
        self.recognized = true
        self.recognizeButton.isEnabled = !self.languages.isEmpty
        if found.isEmpty { self.status.stringValue = localized("No text found", "未识别到文字") }
        self.beginIfReady()
      } catch {
        if !self.closed, self.recognitionID == id {
          self.recognizeButton.isEnabled = !self.languages.isEmpty
          self.status.stringValue = localized("Recognition failed", "识别失败") + ": " + errorMessage(error)
        }
      }
    }
  }

  private func beginIfReady() {
    guard recognized, !languages.isEmpty, !sourceText.string.isEmpty else { return }
    if !userSelectedTarget, languages.indices.contains(targetLanguage.indexOfSelectedItem),
      let source = NLLanguageRecognizer.dominantLanguage(for: sourceText.string)?.rawValue {
      let target = languages[targetLanguage.indexOfSelectedItem].minimalIdentifier
      let fallback = source.hasPrefix("zh") && target.hasPrefix("zh") ? "en"
        : source.hasPrefix("en") && target.hasPrefix("en") ? "zh" : nil
      if let fallback, let index = languages.firstIndex(where: { $0.minimalIdentifier == fallback }) {
        targetLanguage.selectItem(at: index)
      }
    }
    translateButton.isEnabled = true
    startTranslation()
  }

  @objc private func languageChanged(_ sender: Any?) {
    if (sender as? NSPopUpButton) === targetLanguage { userSelectedTarget = true }
    if translating { coordinator.cancel(); translating = false }
    translateButton.isEnabled = recognized && !sourceText.string.isEmpty && !languages.isEmpty
    translatedImage = nil
    imageMode.setEnabled(false, forSegment: 1)
    imageMode.selectedSegment = 0
    copyButton.isEnabled = false
    copyImageButton.isEnabled = false
    saveImageButton.isEnabled = false
    changeImageMode(nil)
    status.stringValue = localized("Choose Translate to use the selected languages", "语言已更改，请重新翻译")
  }

  private func startTranslation() {
    let input = sourceText.string.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard !input.isEmpty, languages.indices.contains(targetLanguage.indexOfSelectedItem) else { return }
    let sourceIndex = sourceLanguage.indexOfSelectedItem - 1
    let source = languages.indices.contains(sourceIndex) ? languages[sourceIndex].minimalIdentifier : nil
    let target = languages[targetLanguage.indexOfSelectedItem].minimalIdentifier
    translating = true
    translateButton.isEnabled = false
    copyButton.isEnabled = false
    copyImageButton.isEnabled = false
    saveImageButton.isEnabled = false
    status.stringValue = localized("Translating on this Mac…", "正在本机翻译…")
    coordinator.start(lines: input, source: source, target: target)
  }

  private func finishTranslation(_ result: Result<[String], Error>) {
    translating = false
    translateButton.isEnabled = !sourceText.string.isEmpty && !languages.isEmpty
    switch result {
    case .success(let translated):
      updating = true
      targetText.string = translated.joined(separator: "\n")
      targetText.isEditable = true
      updating = false
      status.stringValue = localized("Translated on this Mac", "已在本机翻译")
      copyButton.isEnabled = !translated.isEmpty
      updateTranslatedImage()
    case .failure(let error):
      let failure = error as NSError
      if error is CancellationError || (failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError) {
        status.stringValue = localized(
          "When language downloads finish, choose Translate to retry.", "语言包下载完成后，可点击“翻译”重试。")
      } else {
        status.stringValue = localized("Translation failed", "翻译失败") + ": " + errorMessage(error)
      }
    }
  }

  private func updateTranslatedImage() {
    let input = sourceText.string.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let result = targetText.string.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let rendered = input.count == lines.count && result.count == lines.count
      ? try? TranslationImageRenderer.render(image, lines: lines, translated: result) : nil
    translatedImage = rendered?.image
    if rendered?.hasTruncatedText == true {
      status.stringValue = localized("Some image text is shortened; the full translation is on the right.", "译图中部分文字过长已省略，完整译文见右侧。")
    }
    imageMode.setEnabled(translatedImage != nil, forSegment: 1)
    copyImageButton.isEnabled = translatedImage != nil
    saveImageButton.isEnabled = translatedImage != nil
    if translatedImage == nil, !result.isEmpty {
      status.stringValue = localized("Keep one translated line per original line to show it on the image.", "译文与原文保持逐行对应后可显示译图。")
    }
    if translatedImage == nil { imageMode.selectedSegment = 0 }
    changeImageMode(nil)
  }

  @objc private func changeImageMode(_ sender: Any?) {
    let shown = imageMode.selectedSegment == 1 ? translatedImage ?? image : image
    imageView.image = NSImage(cgImage: shown, size: CGSize(width: shown.width, height: shown.height))
  }
  private func copyTranslation() {
    guard !targetText.string.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(targetText.string, forType: .string)
  }
  private func copyTranslatedImage() {
    guard let translatedImage else { return }
    Task {
      do {
        try await ImageRenderer.copy(translatedImage, optimize: Environment.shared.preferences.bool("losslessCompression"))
      } catch { warning(localized("Unable to copy image", "无法复制图片"), errorMessage(error), window: window) }
    }
  }
  private func saveTranslatedImage() {
    guard let translatedImage else { return }
    Task {
      do { _ = try await Files.save(translatedImage, forceDialog: true) }
      catch { warning(localized("Unable to save image", "无法保存图片"), errorMessage(error), window: window) }
    }
  }
  func textDidChange(_ notification: Notification) {
    guard !updating else { return }
    if notification.object as? NSTextView === sourceText {
      if translating { coordinator.cancel(); translating = false }
      renderTask?.cancel()
      translateButton.isEnabled = !sourceText.string.isEmpty && !languages.isEmpty
      translatedImage = nil
      imageMode.setEnabled(false, forSegment: 1)
      imageMode.selectedSegment = 0
      saveImageButton.isEnabled = false
      copyImageButton.isEnabled = false
      copyButton.isEnabled = false
      changeImageMode(nil)
      status.stringValue = localized("Translate the edited text again", "原文已修改，请重新翻译")
    } else if notification.object as? NSTextView === targetText {
      copyButton.isEnabled = !targetText.string.isEmpty
      copyImageButton.isEnabled = false
      saveImageButton.isEnabled = false
      renderTask?.cancel()
      renderTask = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        self?.updateTranslatedImage()
      }
    }
  }
  func windowWillClose(_ notification: Notification) {
    closed = true
    recognitionID = nil
    renderTask?.cancel()
    coordinator.cancel()
    onClose?(self)
  }
}
