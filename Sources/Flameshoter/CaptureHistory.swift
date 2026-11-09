// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import ImageIO

struct CaptureHistoryEntry: Codable, Sendable {
  let id: UUID
  let created: Date
  let display: String
  // Coordinates are pixel-aligned logical points in the original display.
  let rectangle: CGRect
  let scale: CGFloat
  // Annotation coordinates are relative to the stored image.
  let annotations: [Annotation]
  let payloadFile: String
}

struct CaptureHistorySnapshot: @unchecked Sendable {
  let entry: CaptureHistoryEntry
  let image: CGImage

  static func make(
    document: CaptureDocument, display: String, origin: CGPoint = .zero
  ) throws -> CaptureHistorySnapshot {
    let pixels = document.pixelSelection
    guard !pixels.isEmpty, !pixels.isNull, let image = document.image.cropping(to: pixels) else {
      throw ImageError.emptySelection
    }
    let scale = document.scale
    let offset = CGPoint(x: pixels.minX / scale, y: pixels.minY / scale)
    let annotations = document.annotations.map { original in
      var annotation = original
      annotation.move(by: CGSize(width: -offset.x, height: -offset.y))
      return annotation
    }
    let id = UUID()
    let entry = CaptureHistoryEntry(
      id: id, created: Date(), display: display,
      rectangle: CGRect(
        x: origin.x + offset.x, y: origin.y + offset.y,
        width: pixels.width / scale, height: pixels.height / scale),
      scale: scale, annotations: annotations, payloadFile: "\(id.uuidString).png")
    return CaptureHistorySnapshot(entry: entry, image: image)
  }

  func document(undoLimit: Int) -> CaptureDocument {
    var document = CaptureDocument(image: image, logicalSize: entry.rectangle.size, undoLimit: undoLimit)
    document.selection = CGRect(origin: .zero, size: entry.rectangle.size)
    document.replaceAnnotations(entry.annotations, recordingUndo: false)
    return document
  }

  func composite(over background: CGImage) throws -> CGImage {
    let colorSpace = background.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
      data: nil, width: background.width, height: background.height, bitsPerComponent: 8,
      bytesPerRow: background.width * 4, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageError.renderFailed }
    context.interpolationQuality = .none
    context.draw(background, in: CGRect(x: 0, y: 0, width: background.width, height: background.height))
    let rectangle = entry.rectangle
    context.draw(image, in: CGRect(
      x: rectangle.minX * entry.scale,
      y: CGFloat(background.height) - rectangle.maxY * entry.scale,
      width: rectangle.width * entry.scale, height: rectangle.height * entry.scale))
    guard let image = context.makeImage() else { throw ImageError.renderFailed }
    return image
  }
}

/// Keeps only metadata in memory; image encoding and disk access happen on a serial queue.
final class CaptureHistory: @unchecked Sendable {
  private let directory: URL
  private let manifest: URL
  private let queue = DispatchQueue(label: "io.github.Word2VecT.flameshoter.capture-history", qos: .utility)
  private let onError: @Sendable (Error) -> Void
  private var entries: [CaptureHistoryEntry] = []
  private var loadError: Error?
  private var writeError: Error?

  init(directory: URL, onError: @escaping @Sendable (Error) -> Void) {
    self.directory = directory
    manifest = directory.appendingPathComponent("history.json")
    self.onError = onError
    if FileManager.default.fileExists(atPath: manifest.path) {
      do {
        entries = try JSONDecoder().decode([CaptureHistoryEntry].self, from: Data(contentsOf: manifest))
        guard entries.allSatisfy({ !$0.payloadFile.isEmpty &&
          URL(fileURLWithPath: $0.payloadFile).lastPathComponent == $0.payloadFile }) else {
          throw CocoaError(.fileReadCorruptFile)
        }
      } catch { loadError = error }
    }
  }

  func record(_ snapshot: CaptureHistorySnapshot, limit: Int) {
    guard limit > 0 else { return }
    queue.async {
      guard self.loadError == nil else { self.onError(self.loadError!); return }
      let entry = snapshot.entry
      let payload = self.directory.appendingPathComponent(entry.payloadFile)
      do {
        try self.prepareDirectory()
        try ImageEncoder.data(snapshot.image).write(to: payload, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)
        var updated = self.entries + [entry]
        let removed = updated.count > limit ? Array(updated.prefix(updated.count - limit)) : []
        if !removed.isEmpty { updated.removeFirst(removed.count) }
        try self.writeManifest(updated)
        self.entries = updated
        for old in removed { try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(old.payloadFile)) }
      } catch {
        try? FileManager.default.removeItem(at: payload)
        self.writeError = error
        self.onError(error)
      }
    }
  }

  func list(
    display: String, bounds: CGRect, scale: CGFloat, limit: Int,
    completion: @escaping @Sendable (Result<[CaptureHistoryEntry], Error>) -> Void
  ) {
    queue.async {
      let result: Result<[CaptureHistoryEntry], Error>
      if let error = self.loadError { result = .failure(error) }
      else {
        let compatible = self.entries.filter {
          $0.display == display && abs($0.scale - scale) < 0.0001 && bounds.contains($0.rectangle)
        }
        result = .success(limit > 0 ? Array(compatible.suffix(limit)) : [])
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func snapshot(
    id: UUID, completion: @escaping @Sendable (Result<CaptureHistorySnapshot, Error>) -> Void
  ) {
    queue.async {
      let result: Result<CaptureHistorySnapshot, Error>
      do {
        if let error = self.loadError { throw error }
        guard let entry = self.entries.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        let url = self.directory.appendingPathComponent(entry.payloadFile)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        result = .success(CaptureHistorySnapshot(entry: entry, image: image))
      } catch { result = .failure(error) }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func clear(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    queue.async {
      let result: Result<Void, Error>
      do {
        if FileManager.default.fileExists(atPath: self.directory.path) {
          try FileManager.default.removeItem(at: self.directory)
        }
        self.entries = []
        self.loadError = nil
        self.writeError = nil
        result = .success(())
      } catch { result = .failure(error) }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func flush(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    queue.async {
      let result: Result<Void, Error> = (self.loadError ?? self.writeError).map { .failure($0) } ?? .success(())
      DispatchQueue.main.async { completion(result) }
    }
  }

  private func prepareDirectory() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  private func writeManifest(_ entries: [CaptureHistoryEntry]) throws {
    try JSONEncoder().encode(entries).write(to: manifest, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
  }
}
