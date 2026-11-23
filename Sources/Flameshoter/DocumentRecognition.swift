// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import UniformTypeIdentifiers
import Vision

enum DocumentRecognition {
  static func text(_ image: CGImage) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      var request = RecognizeDocumentsRequest()
      let supported = request.supportedRecognitionLanguages
      let requested = Array(Locale.preferredLanguages.prefix(2)) + ["zh-Hans", "en-US"]
      var languages: [Locale.Language] = []
      for raw in requested {
        let match =
          supported.first { $0.minimalIdentifier == raw }
          ?? supported.first {
            $0.minimalIdentifier.split(separator: "-").first == raw.split(separator: "-").first
          }
        if let match, !languages.contains(match) { languages.append(match) }
      }
      if !languages.isEmpty { request.textRecognitionOptions.recognitionLanguages = languages }
      let documents = try await request.perform(on: image)
      return documents.map { $0.document.text.transcript }.joined(separator: "\n\n")
    }.value
  }
}

@MainActor enum DocumentExport {
  enum Format: String, CaseIterable {
    case docx, rtf, txt, md
    var label: String {
      switch self {
      case .docx: return "Word (.docx)"
      case .rtf: return "Rich Text (.rtf)"
      case .txt: return "Text (.txt)"
      case .md: return "Markdown (.md)"
      }
    }
    var contentType: UTType { UTType(filenameExtension: rawValue) ?? .plainText }
  }
  static func data(_ text: String, format: Format) throws -> Data {
    if format == .txt || format == .md { return Data(text.utf8) }
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = 8
    let attributed = NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph,
        .foregroundColor: NSColor.black,
      ])
    return try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [
        .documentType: format == .docx ? NSAttributedString.DocumentType.officeOpenXML : .rtf
      ])
  }
}
