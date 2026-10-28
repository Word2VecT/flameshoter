// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The system owns the share sheet and available services. Retain the snapshot
/// and delegate until sharing finishes so a standalone capture cannot exit early.
@MainActor
final class CaptureSharing: NSObject, @MainActor NSSharingServicePickerDelegate,
  NSSharingServiceDelegate
{
  let item: NSImage
  let picker: NSSharingServicePicker
  private var service: NSSharingService?
  var onBegin: (() -> Void)?
  var onFinish: ((Result<Bool, Error>) -> Void)?
  init(image: CGImage) {
    item = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    picker = NSSharingServicePicker(items: [item])
    super.init()
    picker.delegate = self
  }
  func show(relativeTo rect: NSRect, of view: NSView) {
    picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
  }
  func cancelPicker() {
    if service == nil { picker.close() }
  }
  func close() {
    picker.delegate = nil
    picker.close()
    service?.delegate = nil
    onBegin = nil
    onFinish = nil
  }
  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker,
    delegateFor sharingService: NSSharingService
  ) -> (any NSSharingServiceDelegate)? {
    self
  }
  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker,
    didChoose service: NSSharingService?
  ) {
    guard onFinish != nil else { return }
    if let service {
      self.service = service
      onBegin?()
    } else if self.service == nil {
      finish(.success(false))
    }
  }
  func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
    finish(.success(true))
  }
  func sharingService(
    _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error
  ) {
    finish(.failure(error))
  }
  private func finish(_ result: Result<Bool, Error>) {
    let completion = onFinish
    close()
    completion?(result)
  }
}
