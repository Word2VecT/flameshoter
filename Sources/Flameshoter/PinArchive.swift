// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore

struct ArchivedPin: Codable {
  enum Kind: String, Codable { case image, text, color, file, gif, webP }
  let id: UUID
  let kind: Kind
  let created: Date
  var closed: Date?
  var frame: CGRect
  var opacity: Double
  var payloadFile: String
}

struct LoadedPin {
  let record: ArchivedPin
  let data: Data
}

/// Serializes writes so the manifest always refers to complete payload files.
final class PinArchive: @unchecked Sendable {
  private let directory: URL
  private let manifest: URL
  private let queue = DispatchQueue(
    label: "io.github.Word2VecT.flameshoter.pin-archive", qos: .utility)
  private let onError: @Sendable (Error) -> Void
  private var records: [ArchivedPin] = []
  private var failedToLoad = false
  private var loadFailure: Error?
  private var writeFailure: Error?

  init(directory: URL, onError: @escaping @Sendable (Error) -> Void) {
    self.directory = directory
    manifest = directory.appendingPathComponent("history.json")
    self.onError = onError
    if FileManager.default.fileExists(atPath: manifest.path) {
      do {
        records = try JSONDecoder().decode([ArchivedPin].self, from: Data(contentsOf: manifest))
      } catch {
        failedToLoad = true
        loadFailure = error
      }
    }
  }

  func load(_ completion: @escaping @Sendable (Result<[LoadedPin], Error>) -> Void) {
    queue.async {
      do {
        if let error = self.loadFailure { throw error }
        let loaded = try self.records.map { record in
          guard !record.payloadFile.isEmpty,
            URL(fileURLWithPath: record.payloadFile).lastPathComponent == record.payloadFile
          else { throw CocoaError(.fileReadCorruptFile) }
          return LoadedPin(
            record: record,
            data: try Data(contentsOf: self.directory.appendingPathComponent(record.payloadFile)))
        }
        DispatchQueue.main.async { completion(.success(loaded)) }
      } catch {
        self.failedToLoad = true
        self.loadFailure = error
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  func add(_ record: ArchivedPin, payload: @escaping @Sendable () throws -> Data) {
    queue.async {
      guard !self.failedToLoad else { return }
      do {
        var new = record
        new.payloadFile = try self.writePayload(payload(), id: record.id)
        var updated = self.records
        updated.append(new)
        try self.writeManifest(updated)
        self.records = updated
      } catch {
        self.writeFailure = error
        self.onError(error)
      }
    }
  }

  func update(_ record: ArchivedPin, payload: Data? = nil) {
    queue.async {
      guard !self.failedToLoad, let index = self.records.firstIndex(where: { $0.id == record.id })
      else { return }
      do {
        let previous = self.records[index].payloadFile
        var new = record
        new.payloadFile = try payload.map { try self.writePayload($0, id: record.id) } ?? previous
        var updated = self.records
        updated[index] = new
        try self.writeManifest(updated)
        self.records = updated
        if new.payloadFile != previous {
          try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(previous))
        }
      } catch {
        self.writeFailure = error
        self.onError(error)
      }
    }
  }

  func remove(_ ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    queue.async {
      guard !self.failedToLoad else { return }
      let removed = self.records.filter { ids.contains($0.id) }
      guard !removed.isEmpty else { return }
      let updated = self.records.filter { !ids.contains($0.id) }
      do {
        try self.writeManifest(updated)
        self.records = updated
        for record in removed {
          try? FileManager.default.removeItem(
            at: self.directory.appendingPathComponent(record.payloadFile))
        }
      } catch {
        self.writeFailure = error
        self.onError(error)
      }
    }
  }

  func flush(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    queue.async {
      let result: Result<Void, Error> =
        (self.loadFailure ?? self.writeFailure).map { .failure($0) } ?? .success(())
      DispatchQueue.main.async { completion(result) }
    }
  }

  private func writePayload(_ data: Data, id: UUID) throws -> String {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let name = "\(id.uuidString)-\(UUID().uuidString).data"
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return name
  }
  private func writeManifest(_ records: [ArchivedPin]) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try JSONEncoder().encode(records).write(to: manifest, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
  }
}
