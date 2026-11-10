// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing
import FlameshoterCore
@testable import Flameshoter

@MainActor private func tableFixture(merged: Bool = false) -> CGImage {
  let image = NSImage(size: NSSize(width: 1200, height: 650))
  image.lockFocus()
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: 1200, height: 650).fill()
  NSColor.black.setStroke()
  let grid = NSBezierPath()
  grid.lineWidth = 3
  for x in [60, 420, 780, 1140] {
    grid.move(to: NSPoint(x: x, y: 75)); grid.line(to: NSPoint(x: x, y: merged && x == 420 ? 450 : 575))
  }
  for y in [75, 200, 325, 450, 575] {
    grid.move(to: NSPoint(x: 60, y: y)); grid.line(to: NSPoint(x: 1140, y: y))
  }
  grid.stroke()
  let rows = [merged ? ["Products", "", "Price"] : ["Item", "Quantity", "Price"], ["Pencil", "20", "3.50"],
              ["Notebook", "50", "8.25"], ["Folder", "30", "2.20"]]
  for (row, values) in rows.enumerated() {
    for (column, text) in values.enumerated() {
      (text as NSString).draw(at: NSPoint(x: 90 + 360 * column, y: 495 - 125 * row),
        withAttributes: [.font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black])
    }
  }
  image.unlockFocus()
  return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

@Test @MainActor func systemRecognizesTableRowsAndColumns() async throws {
  _ = NSApplication.shared
  let tables = try await TableRecognition.tables(tableFixture())
  let table = try #require(tables.first)
  #expect(table.rowCount == 4)
  #expect(table.columnCount == 3)
  #expect(table.value(row: 0, column: 0) == "Item")
  #expect(table.value(row: 1, column: 0) == "Pencil")
  #expect(table.value(row: 1, column: 2) == "3.50")
  #expect(table.value(row: 3, column: 1) == "30")
  let merged = try #require(try await TableRecognition.tables(tableFixture(merged: true)).first)
  let header = try #require(merged.cells.first { $0.text == "Products" })
  #expect(header.rows == 0...0)
  #expect(header.columns == 0...1)
}

@Test func tableEditsAndDelimitedExportsPreserveCells() {
  var table = RecognizedTable(rowCount: 2, columnCount: 3, cells: [
    .init(rows: 0...0, columns: 0...1, text: "合并,标题"),
    .init(rows: 1...1, columns: 0...0, text: "A\"B"),
    .init(rows: 1...1, columns: 2...2, text: "line\nbreak"),
  ])
  #expect(!table.isEditable(row: 0, column: 1))
  table.setValue("ignored", row: 0, column: 1)
  table.setValue("20", row: 1, column: 1)
  #expect(table.delimited(separator: ",") == "\"合并,标题\",,\r\n\"A\"\"B\",20,\"line\nbreak\"")
  #expect(table.delimited(separator: ",", fillMerged: true).hasPrefix("\"合并,标题\",\"合并,标题\","))
  #expect(table.value(row: 0, column: 1, fillMerged: true) == "合并,标题")
}

private func zipEntry(_ url: URL, _ entry: String) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
  process.arguments = ["-p", url.path, entry]
  let output = Pipe()
  process.standardOutput = output
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
  return String(decoding: data, as: UTF8.self)
}

@Test func excelExportPreservesMergedCellsAndText() throws {
  let table = RecognizedTable(rowCount: 3, columnCount: 3, cells: [
    .init(rows: 0...0, columns: 0...1, text: "合并标题"),
    .init(rows: 1...1, columns: 0...0, text: "=1+2"),
    .init(rows: 1...1, columns: 1...1, text: "3.50"),
    .init(rows: 1...1, columns: 2...2, text: "30 & 40"),
    .init(rows: 2...2, columns: 0...0, text: "00123"),
    .init(rows: 2...2, columns: 1...1, text: "20"),
  ])
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
  defer { try? FileManager.default.removeItem(at: url) }
  try TableExport.xlsx(table).write(to: url)
  let sheet = try zipEntry(url, "xl/worksheets/sheet1.xml")
  let strings = try zipEntry(url, "xl/sharedStrings.xml")
  #expect(sheet.contains("mergeCell ref=\"A1:B1\""))
  #expect(!sheet.contains("<f>"))
  #expect(strings.contains("合并标题"))
  #expect(strings.contains("=1+2"))
  #expect(strings.contains("30 &amp; 40"))
  #expect(strings.contains("00123"))
  #expect(sheet.contains("<v>3.5</v>"))
  #expect(sheet.contains("<v>20</v>"))
  #expect(try zipEntry(url, "xl/styles.xml").contains("formatCode=\"0.00\""))
  #expect(TableExport.number("00123") == nil)
  #expect(TableExport.number("1234567890123456") == nil)
  #expect(TableExport.number("-0.0") == nil)
}

@Test @MainActor func pinOffersTableRecognitionUsingOriginalImage() throws {
  _ = NSApplication.shared
  let image = tableFixture()
  let pin = PinWindowController(image: image)
  defer { pin.window?.close() }
  var received: CGImage?
  pin.onRecognizeTable = { received = $0 }
  let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  let menu = try #require(pin.imageView.menu(for: event))
  #expect(menu.items.contains { $0.action == #selector(PinWindowController.recognizeTable(_:)) })
  pin.recognizeTable(nil)
  #expect(received === image)
}

@Test func tableRecognitionUpgradePreservesShortcutConflict() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("settings.json")
  var old = Preferences()
  old.schemaVersion = 11
  old.tools = [.copy]
  old.shortcuts["TYPE_COPY"] = Shortcut(12, [.shift])
  try JSONEncoder().encode(old).write(to: url)
  let updated = SettingsStore(url: url).preferences
  #expect(updated.tools == [.copy, .recognizeTable])
  #expect(updated.shortcut("TYPE_COPY") == Shortcut(12, [.shift]))
  #expect(updated.shortcut(Tool.recognizeTable.legacyName) == nil)
}

@Test func tableSortingMovesWholeRowsAndKeepsHeader() throws {
  let table = RecognizedTable(rowCount: 4, columnCount: 3, cells: [
    .init(rows: 0...0, columns: 0...1, text: "商品"),
    .init(rows: 0...0, columns: 2...2, text: "价格"),
    .init(rows: 1...1, columns: 0...0, text: "A"),
    .init(rows: 1...1, columns: 2...2, text: "1,200.50"),
    .init(rows: 2...2, columns: 0...0, text: "B"),
    .init(rows: 2...2, columns: 2...2, text: "20"),
    .init(rows: 3...3, columns: 0...0, text: "C"),
    .init(rows: 3...3, columns: 2...2, text: "3"),
  ])
  let sorted = try #require(table.sorted(column: 2, ascending: true, keepHeader: true))
  #expect((0..<4).map { sorted.value(row: $0, column: 0) } == ["商品", "C", "B", "A"])
  #expect(sorted.cells.contains { $0.rows == 0...0 && $0.columns == 0...1 && $0.text == "商品" })
  let descending = try #require(table.sorted(column: 2, ascending: false, keepHeader: true))
  #expect((1..<4).map { descending.value(row: $0, column: 0) } == ["A", "B", "C"])
  var mergedRows = table
  mergedRows.cells.append(.init(rows: 1...2, columns: 1...1, text: "合并"))
  #expect(mergedRows.sorted(column: 2, ascending: true, keepHeader: true) == nil)
}

@Test func tableRowAndColumnChangesKeepMergedRangesConsistent() throws {
  var table = RecognizedTable(rowCount: 3, columnCount: 3, cells: [
    .init(rows: 0...0, columns: 0...0, text: "Header"),
    .init(rows: 1...2, columns: 1...2, text: "Merged"),
  ])
  table.insert(2, rows: true)
  table.insert(2, rows: false)
  #expect(table.rowCount == 4 && table.columnCount == 4)
  #expect(table.cells.contains { $0.text == "Merged" && $0.rows == 1...3 && $0.columns == 1...3 })
  table.remove(1, rows: true)
  table.remove(1, rows: false)
  #expect(table.rowCount == 3 && table.columnCount == 3)
  #expect(table.cells.contains { $0.text == "Merged" && $0.rows == 1...2 && $0.columns == 1...2 })
  table.split(row: 2, column: 2)
  #expect(table.cells.contains { $0.text == "Merged" && $0.rows == 1...1 && $0.columns == 1...1 })
  #expect(table.isEditable(row: 2, column: 2))
  table.remove(0, rows: true)
  #expect(table.rowCount == 2)
  #expect(table.value(row: 0, column: 1) == "Merged")
  #expect(!table.cells.contains { $0.text == "Header" })
}
