// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore

@MainActor final class ImageExportPreview: NSView {
  private let image: CGImage
  private let optimize: Bool
  private let original = NSImageView()
  private let encoded = NSImageView()
  private let status = NSTextField(labelWithString: "")
  private let qualitySlider: ActionSlider
  private let qualityLabel = NSTextField(labelWithString: "")
  private let qualityRow: NSStackView
  private var task: Task<Void, Never>?
  private var generation = 0
  private(set) var encodedData: Data?
  private(set) var format: String
  private(set) var quality: Int
  var onQualityChange: ((Int) -> Void)?
  private let encoder: @MainActor (CGImage, String, Int, Bool) async throws -> Data

  init(
    image: CGImage, format: String, quality: Int, optimize: Bool,
    encoder: @escaping @MainActor (CGImage, String, Int, Bool) async throws -> Data = {
      try await ImageEncoder.encode($0, format: $1, quality: $2, optimize: $3)
    }
  ) {
    self.image = image
    self.format = format
    self.quality = quality
    self.optimize = optimize
    self.encoder = encoder
    qualitySlider = ActionSlider(Double(quality), min: 1, max: 100) { _ in }
    qualityRow = stack([], vertical: false)
    super.init(frame: .zero)
    original.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    for (view, title) in [
      (original, localized("Original", "原图")), (encoded, localized("Export preview", "导出预览")),
    ] {
      view.imageScaling = .scaleProportionallyUpOrDown
      view.setAccessibilityLabel(title)
      view.widthAnchor.constraint(equalToConstant: 160).isActive = true
      view.heightAnchor.constraint(equalToConstant: 100).isActive = true
    }
    let comparisons = stack(
      [
        stack([label(localized("Original", "原图"), size: 11), original], spacing: 4),
        stack([label(localized("Export preview", "导出预览"), size: 11), encoded], spacing: 4),
      ], vertical: false, spacing: 12)
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    qualityRow.addArrangedSubview(qualityLabel)
    qualityRow.addArrangedSubview(qualitySlider)
    qualitySlider.setAccessibilityLabel(localized("Image quality", "图片质量"))
    qualitySlider.change = { [weak self] value in
      guard let self else { return }
      self.quality = Int(value.rounded())
      self.onQualityChange?(self.quality)
      self.request(format: self.format)
    }
    let content = stack([comparisons, qualityRow, status], spacing: 8)
    addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
      content.topAnchor.constraint(equalTo: topAnchor),
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    request(format: format)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  func request(format: String) {
    self.format = format
    qualityRow.isHidden = !["jpeg", "jpg", "avif"].contains(format)
    qualityLabel.stringValue = localized("Quality", "质量") + " \(quality)%"
    generation += 1
    let expected = generation
    task?.cancel()
    encodedData = nil
    encoded.image = nil
    status.stringValue = localized("Preparing export preview…", "正在生成导出预览…")
    let quality = self.quality
    task = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .milliseconds(180))
        let data = try await self.encoder(self.image, format, quality, self.optimize)
        guard !Task.isCancelled, self.generation == expected else { return }
        self.encodedData = data
        self.encoded.image = NSImage(data: data)
        self.status.stringValue =
          "\(self.image.width) × \(self.image.height) · "
          + ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
      } catch {
        guard !Task.isCancelled, self.generation == expected else { return }
        self.status.stringValue = localized("Preview failed", "预览失败") + ": " + errorMessage(error)
      }
    }
  }
  func cancel() {
    task?.cancel()
    generation += 1
  }
}
