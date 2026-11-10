// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CXLSXWriter
import FlameshoterCore
import UniformTypeIdentifiers
import Vision

struct RecognizedTable: Sendable, Equatable {
  struct Cell: Sendable, Equatable {
    var rows: ClosedRange<Int>
    var columns: ClosedRange<Int>
    var text: String
  }
  var rowCount: Int
  var columnCount: Int
  var cells: [Cell]

  func cellIndex(row: Int, column: Int) -> Int? {
    cells.firstIndex { $0.rows.contains(row) && $0.columns.contains(column) }
  }
  func isEditable(row: Int, column: Int) -> Bool {
    guard let index = cellIndex(row: row, column: column) else { return true }
    let cell = cells[index]
    return cell.rows.lowerBound == row && cell.columns.lowerBound == column
  }
  func value(row: Int, column: Int, fillMerged: Bool = false) -> String {
    guard let index = cellIndex(row: row, column: column) else { return "" }
    let cell = cells[index]
    return fillMerged || (cell.rows.lowerBound == row && cell.columns.lowerBound == column) ? cell.text : ""
  }
  mutating func setValue(_ value: String, row: Int, column: Int) {
    guard isEditable(row: row, column: column) else { return }
    if let index = cellIndex(row: row, column: column) { cells[index].text = value }
    else { cells.append(Cell(rows: row...row, columns: column...column, text: value)) }
  }
  var hasMergedCells: Bool { cells.contains { $0.rows.count > 1 || $0.columns.count > 1 } }
  mutating func insert(_ index: Int, rows: Bool) {
    cells = cells.map { original in
      var cell = original
      let range = rows ? cell.rows : cell.columns
      let updated = index <= range.lowerBound ? (range.lowerBound + 1)...(range.upperBound + 1)
        : index <= range.upperBound ? range.lowerBound...(range.upperBound + 1) : range
      if rows { cell.rows = updated } else { cell.columns = updated }
      return cell
    }
    if rows { rowCount += 1 } else { columnCount += 1 }
  }
  mutating func remove(_ index: Int, rows: Bool) {
    cells = cells.compactMap { original in
      var cell = original
      let range = rows ? cell.rows : cell.columns
      if range.contains(index), range.count == 1 { return nil }
      let updated = index < range.lowerBound ? (range.lowerBound - 1)...(range.upperBound - 1)
        : range.contains(index) ? range.lowerBound...(range.upperBound - 1) : range
      if rows { cell.rows = updated } else { cell.columns = updated }
      return cell
    }
    if rows { rowCount -= 1 } else { columnCount -= 1 }
  }
  mutating func split(row: Int, column: Int) {
    guard let index = cellIndex(row: row, column: column) else { return }
    let cell = cells[index]
    cells[index].rows = cell.rows.lowerBound...cell.rows.lowerBound
    cells[index].columns = cell.columns.lowerBound...cell.columns.lowerBound
  }
  func sorted(column: Int, ascending: Bool, keepHeader: Bool) -> RecognizedTable? {
    guard !cells.contains(where: { $0.rows.count > 1 }) else { return nil }
    let first = keepHeader ? min(1, rowCount) : 0
    let rows = Array(first..<rowCount)
    var texts = Array(repeating: "", count: rowCount)
    for cell in cells where cell.columns.lowerBound == column {
      texts[cell.rows.lowerBound] = cell.text
    }
    let normalized = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    func number(_ text: String) -> Double? {
      if let value = Double(text), value.isFinite { return value }
      let parts = text.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count <= 2, parts.count == 1 || (!parts[1].isEmpty && parts[1].utf8.allSatisfy({ (48...57).contains($0) })) else { return nil }
      let groups = parts[0].split(separator: ",", omittingEmptySubsequences: false)
      guard groups.count > 1, !groups[0].isEmpty,
        groups.dropFirst().allSatisfy({ $0.count == 3 && $0.utf8.allSatisfy { (48...57).contains($0) } })
      else { return nil }
      return Double(text.replacingOccurrences(of: ",", with: ""))
    }
    let numbers = normalized.map(number)
    let numeric = rows.filter { !normalized[$0].isEmpty }.allSatisfy { numbers[$0] != nil }
    let order = rows.sorted { left, right in
      let a = texts[left], b = texts[right]
      let aEmpty = normalized[left].isEmpty, bEmpty = normalized[right].isEmpty
      if aEmpty != bEmpty { return !aEmpty }
      let comparison: ComparisonResult
      if numeric, let x = numbers[left], let y = numbers[right] {
        comparison = x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
      } else { comparison = a.localizedStandardCompare(b) }
      if comparison == .orderedSame { return left < right }
      return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
    var newRow = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset + first) })
    if first == 1 { newRow[0] = 0 }
    var result = self
    result.cells = cells.map { cell in
      var copy = cell
      let row = newRow[cell.rows.lowerBound]!
      copy.rows = row...row
      return copy
    }
    return result
  }
  func delimited(separator: String, fillMerged: Bool = false) -> String {
    var values = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
    for cell in cells {
      let rows = fillMerged ? cell.rows : cell.rows.lowerBound...cell.rows.lowerBound
      let columns = fillMerged ? cell.columns : cell.columns.lowerBound...cell.columns.lowerBound
      for row in rows { for column in columns { values[row][column] = cell.text } }
    }
    return values.map { row in
      row.map { text in
        if text.contains(separator) || text.contains("\n") || text.contains("\r") || text.contains("\"") {
          return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return text
      }.joined(separator: separator)
    }.joined(separator: "\r\n")
  }
}

enum TableRecognition {
  static func tables(_ image: CGImage) async throws -> [RecognizedTable] {
    try await Task.detached(priority: .userInitiated) {
      var request = RecognizeDocumentsRequest()
      let supported = request.supportedRecognitionLanguages
      let preferred = Array(Locale.preferredLanguages.prefix(2)) + ["zh-Hans", "en-US"]
      var selected: [Locale.Language] = []
      for identifier in preferred {
        let normalized = identifier == "zh-TW" || identifier == "zh-HK" ? "zh-Hant" : identifier
        let match = supported.first { $0.minimalIdentifier.caseInsensitiveCompare(normalized) == .orderedSame }
          ?? supported.first { $0.minimalIdentifier.split(separator: "-").first == normalized.split(separator: "-").first }
        if let match, !selected.contains(match) { selected.append(match) }
      }
      if !selected.isEmpty { request.textRecognitionOptions.recognitionLanguages = selected }
      let observations = try await request.perform(on: image)
      return observations.flatMap { $0.document.tables }.map { table in
        var seen: Set<Int> = []
        var cells: [RecognizedTable.Cell] = []
        let rowCount = table.rows.count, columnCount = table.columns.count
        for row in 0..<rowCount {
          for column in 0..<columnCount {
            guard let cell = table.cell(row: row, col: column) else { continue }
            let key = cell.rowRange.lowerBound * columnCount + cell.columnRange.lowerBound
            guard seen.insert(key).inserted else { continue }
            cells.append(.init(rows: cell.rowRange, columns: cell.columnRange, text: cell.content.text.transcript))
          }
        }
        return RecognizedTable(rowCount: rowCount, columnCount: columnCount, cells: cells)
      }
    }.value
  }
}

enum TableExportError: LocalizedError {
  case create, library(String)
  var errorDescription: String? {
    switch self {
    case .create: return "Unable to create the spreadsheet."
    case .library(let message): return message
    }
  }
}

private enum TableCellCommand: Int {
  case insertAbove, insertBelow, removeRow, insertLeft, insertRight, removeColumn, clear, split
}

@MainActor final class RecognizedTableView: NSTableView {
  var menuForCell: ((Int, Int) -> NSMenu?)?
  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    let row = row(at: point), column = column(at: point)
    guard row >= 0, column >= 0 else { return super.menu(for: event) }
    return menuForCell?(row, column)
  }
}

enum TableExport {
  // Keep identifiers with leading zeroes and values beyond Excel's 15-digit precision as text.
  static func number(_ text: String) -> (Double, Int)? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { return nil }
    let integer = parts[0].first == "-" ? parts[0].dropFirst() : parts[0][...]
    let fraction = parts.count == 2 ? parts[1] : Substring()
    func digits(_ value: Substring) -> Bool { !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } }
    guard digits(integer), (parts.count == 1 || digits(fraction)),
      !(integer.count > 1 && integer.first == "0"), integer.count + fraction.count <= 15,
      let value = Double(text), value.isFinite, !(text.first == "-" && value == 0)
    else { return nil }
    return (value, fraction.count)
  }

  static func xlsx(_ table: RecognizedTable) throws -> Data {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("table.xlsx")
    guard let workbook = workbook_new(file.path) else { throw TableExportError.create }
    guard let sheet = workbook_add_worksheet(workbook, nil) else {
      _ = workbook_close(workbook)
      throw TableExportError.create
    }
    var failure: lxw_error = LXW_NO_ERROR
    var formats: [Int: UnsafeMutablePointer<lxw_format>] = [:]
    for cell in table.cells {
      let numeric = number(cell.text)
      var format: UnsafeMutablePointer<lxw_format>?
      if let numeric, numeric.1 > 0 {
        if let existing = formats[numeric.1] { format = existing }
        else if let created = workbook_add_format(workbook) {
          format_set_num_format(created, "0." + String(repeating: "0", count: numeric.1))
          formats[numeric.1] = created
          format = created
        } else {
          _ = workbook_close(workbook)
          throw TableExportError.create
        }
      }
      let result: lxw_error = cell.text.withCString { text in
        if cell.rows.count > 1 || cell.columns.count > 1 {
          let merged = worksheet_merge_range(sheet, lxw_row_t(cell.rows.lowerBound), lxw_col_t(cell.columns.lowerBound),
            lxw_row_t(cell.rows.upperBound), lxw_col_t(cell.columns.upperBound), text, format)
          if merged != LXW_NO_ERROR { return merged }
          if let numeric {
            return worksheet_write_number(sheet, lxw_row_t(cell.rows.lowerBound), lxw_col_t(cell.columns.lowerBound), numeric.0, format)
          }
          return merged
        }
        if let numeric {
          return worksheet_write_number(sheet, lxw_row_t(cell.rows.lowerBound), lxw_col_t(cell.columns.lowerBound), numeric.0, format)
        }
        return worksheet_write_string(sheet, lxw_row_t(cell.rows.lowerBound), lxw_col_t(cell.columns.lowerBound), text, nil)
      }
      if result != LXW_NO_ERROR { failure = result; break }
    }
    let closing = workbook_close(workbook)
    let result = failure == LXW_NO_ERROR ? closing : failure
    guard result == LXW_NO_ERROR else { throw TableExportError.library(String(cString: lxw_strerror(result))) }
    return try Data(contentsOf: file)
  }
}

@MainActor final class TableRecognitionWindowController: NSWindowController, NSWindowDelegate,
  NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate
{
  private let image: CGImage
  private let imageView = NSImageView()
  private let tableView = RecognizedTableView()
  private let tablePicker = NSPopUpButton()
  private let status = NSTextField(labelWithString: "")
  private let copyButton = ActionButton("", action: {})
  private let csvButton = ActionButton("", action: {})
  private let excelButton = ActionButton("", action: {})
  private let headerCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private let edits = UndoManager()
  private var tables: [RecognizedTable] = []
  private var selected = 0
  private var task: Task<Void, Never>?
  private var closed = false
  private var changingSort = false
  var onClose: ((TableRecognitionWindowController) -> Void)?

  init(image: CGImage) {
    self.image = image
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 550),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = localized("Table recognition", "表格识别")
    window.minSize = NSSize(width: 640, height: 340)
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    buildView()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func buildView() {
    guard let window else { return }
    let root = NSView()
    window.contentView = root
    tablePicker.setAccessibilityLabel(localized("Recognized table", "识别的表格"))
    tablePicker.target = self
    tablePicker.action = #selector(tableChanged(_:))
    tablePicker.isEnabled = false
    status.stringValue = localized("Recognizing on this Mac…", "正在本机识别…")
    status.textColor = .secondaryLabelColor
    status.lineBreakMode = .byTruncatingTail
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let header = NSStackView(views: [tablePicker, status, NSView()])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 10
    header.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(header)
    let split = NSSplitView()
    split.isVertical = true
    split.dividerStyle = .thin
    split.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(split)
    let container = NSView()
    imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    imageView.setAccessibilityLabel(localized("Original image", "原始图像"))
    imageView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: container.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      container.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
    ])
    split.addArrangedSubview(container)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.borderType = .bezelBorder
    tableView.dataSource = self
    tableView.delegate = self
    tableView.menuForCell = { [weak self] row, column in
      guard let self, self.tables.indices.contains(self.selected), row < self.tables[self.selected].rowCount,
        column < self.tables[self.selected].columnCount else { return nil }
      return self.cellMenu(row: row, column: column)
    }
    tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.allowsColumnReordering = false
    tableView.rowHeight = 26
    tableView.setAccessibilityLabel(localized("Recognized cells", "识别的单元格"))
    tableView.setAccessibilityHelp(localized("Click a column header to sort; click again to reverse.", "点击列标题排序，再次点击可反向排序。"))
    scroll.documentView = tableView
    scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    split.addArrangedSubview(scroll)
    copyButton.title = localized("Copy table", "复制表格")
    copyButton.invoke = { [weak self] in self?.copyTable() }
    csvButton.title = localized("Save CSV…", "保存 CSV…")
    csvButton.invoke = { [weak self] in self?.saveTable(excel: false) }
    excelButton.title = localized("Save Excel…", "保存 Excel…")
    excelButton.invoke = { [weak self] in self?.saveTable(excel: true) }
    [copyButton, csvButton, excelButton].forEach { $0.isEnabled = false }
    headerCheckbox.title = localized("First row is a header", "首行为标题")
    headerCheckbox.toolTip = localized("Keep the first row in place when sorting.", "排序时保留第一行。")
    let bottom = NSStackView(views: [headerCheckbox, NSView(), copyButton, csvButton, excelButton])
    bottom.orientation = .horizontal
    bottom.alignment = .centerY
    bottom.spacing = 10
    bottom.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(bottom)
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
    ])
    window.layoutIfNeeded()
    split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
  }
  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
    task = Task { [weak self, image] in
      do {
        let found = try await TableRecognition.tables(image)
        guard let self, !self.closed else { return }
        self.tables = found
        self.tablePicker.removeAllItems()
        self.tablePicker.addItems(withTitles: found.indices.map { localized("Table", "表格") + " \($0 + 1)" })
        self.tablePicker.isEnabled = found.count > 1
        self.showSelectedTable()
      } catch {
        guard let self, !self.closed else { return }
        self.status.stringValue = localized("Recognition failed", "识别失败") + ": " + errorMessage(error)
      }
    }
  }
  @objc private func tableChanged(_ sender: Any?) {
    window?.makeFirstResponder(nil)
    selected = tablePicker.indexOfSelectedItem
    edits.removeAllActions()
    showSelectedTable()
  }
  private func showSelectedTable() {
    changingSort = true
    tableView.sortDescriptors = []
    changingSort = false
    for column in tableView.tableColumns { tableView.removeTableColumn(column) }
    guard tables.indices.contains(selected) else {
      status.stringValue = localized("No table found", "未识别到表格")
      [copyButton, csvButton, excelButton].forEach { $0.isEnabled = false }
      tableView.reloadData()
      return
    }
    let table = tables[selected]
    for column in 0..<table.columnCount {
      let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(column)))
      item.title = columnName(column)
      item.width = 145
      item.minWidth = 60
      item.sortDescriptorPrototype = NSSortDescriptor(key: String(column), ascending: true)
      tableView.addTableColumn(item)
    }
    updateDimensions()
    [copyButton, csvButton, excelButton].forEach { $0.isEnabled = true }
    tableView.reloadData()
  }
  private func updateDimensions() {
    guard tables.indices.contains(selected) else { return }
    let table = tables[selected]
    status.stringValue = localized("Recognized on this Mac", "已在本机识别") + " · \(table.rowCount) × \(table.columnCount)"
  }
  private func columnName(_ index: Int) -> String {
    var number = index + 1, name = ""
    while number > 0 {
      number -= 1
      name = String(UnicodeScalar(65 + number % 26)!) + name
      number /= 26
    }
    return name
  }
  func numberOfRows(in tableView: NSTableView) -> Int { tables.indices.contains(selected) ? tables[selected].rowCount : 0 }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }), tables.indices.contains(selected) else { return nil }
    let view = NSTableCellView()
    let field = NSTextField()
    field.isBordered = false
    field.drawsBackground = false
    field.font = .systemFont(ofSize: 13)
    field.lineBreakMode = .byTruncatingTail
    field.stringValue = tables[selected].value(row: row, column: column)
    field.isEditable = tables[selected].isEditable(row: row, column: column)
    field.isSelectable = field.isEditable
    if !field.isEditable {
      field.toolTip = localized("Edit the top-left cell of this merged range.", "合并单元格请编辑左上角。")
    }
    field.tag = column
    field.delegate = self
    field.menu = cellMenu(row: row, column: column)
    view.menu = field.menu
    field.setAccessibilityLabel(localized("Row", "第") + " \(row + 1) " + localized("column", "行，第") + " \(column + 1) " + localized("cell", "列"))
    field.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(field)
    view.textField = field
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
      field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
      field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    return view
  }
  func controlTextDidEndEditing(_ notification: Notification) {
    guard let field = notification.object as? NSTextField, tables.indices.contains(selected) else { return }
    let row = tableView.row(for: field), column = field.tag
    guard row >= 0, row < tables[selected].rowCount, column >= 0, column < tables[selected].columnCount else { return }
    var table = tables[selected]
    table.setValue(field.stringValue, row: row, column: column)
    updateTable(table, index: selected, name: localized("Edit cell", "编辑单元格"), reload: false)
  }
  private func cellMenu(row: Int, column: Int) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let table = tables[selected]
    let merged = table.cellIndex(row: row, column: column).map {
      table.cells[$0].rows.count > 1 || table.cells[$0].columns.count > 1
    } ?? false
    let commands: [(String, TableCellCommand, Bool)] = [
      (localized("Insert row above", "在上方插入行"), .insertAbove, true),
      (localized("Insert row below", "在下方插入行"), .insertBelow, true),
      (localized("Delete row", "删除行"), .removeRow, table.rowCount > 1),
      (localized("Insert column left", "在左侧插入列"), .insertLeft, true),
      (localized("Insert column right", "在右侧插入列"), .insertRight, true),
      (localized("Delete column", "删除列"), .removeColumn, table.columnCount > 1),
      (localized("Clear cell", "清空单元格"), .clear, true),
      (localized("Split merged cell", "拆分合并单元格"), .split, merged),
    ]
    for (title, command, enabled) in commands {
      let item = NSMenuItem(title: title, action: #selector(editTable(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = [row, column, command.rawValue]
      item.isEnabled = enabled
      menu.addItem(item)
    }
    return menu
  }
  @objc private func editTable(_ sender: NSMenuItem) {
    window?.makeFirstResponder(nil)
    guard tables.indices.contains(selected), let position = sender.representedObject as? [Int],
      position.count == 3, let command = TableCellCommand(rawValue: position[2]) else { return }
    let row = position[0], column = position[1]
    var table = tables[selected]
    guard row < table.rowCount, column < table.columnCount else { return }
    switch command {
    case .insertAbove: table.insert(row, rows: true)
    case .insertBelow: table.insert(row + 1, rows: true)
    case .removeRow: if table.rowCount > 1 { table.remove(row, rows: true) }
    case .insertLeft: table.insert(column, rows: false)
    case .insertRight: table.insert(column + 1, rows: false)
    case .removeColumn: if table.columnCount > 1 { table.remove(column, rows: false) }
    case .clear:
      if let index = table.cellIndex(row: row, column: column) { table.cells[index].text = "" }
    case .split: table.split(row: row, column: column)
    }
    updateTable(table, index: selected, name: sender.title)
  }
  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { edits }
  private func updateTable(_ value: RecognizedTable, index: Int, name: String, reload: Bool = true) {
    guard tables.indices.contains(index), tables[index] != value else { return }
    let previous = tables[index]
    edits.registerUndo(withTarget: self) { target in target.updateTable(previous, index: index, name: name) }
    edits.setActionName(name)
    tables[index] = value
    if index == selected { updateDimensions() }
    if reload, index == selected, previous.columnCount != value.columnCount {
      showSelectedTable()
    } else if reload, index == selected {
      changingSort = true
      tableView.sortDescriptors = []
      changingSort = false
      tableView.reloadData()
    }
  }
  func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
    guard !changingSort, tables.indices.contains(selected), let sort = tableView.sortDescriptors.first,
      let key = sort.key, let column = Int(key), column < tables[selected].columnCount else { return }
    window?.makeFirstResponder(nil)
    guard let sorted = tables[selected].sorted(column: column, ascending: sort.ascending,
                                               keepHeader: headerCheckbox.state == .on) else {
      changingSort = true
      tableView.sortDescriptors = oldDescriptors
      changingSort = false
      warning(localized("Cannot sort merged rows", "无法排序跨行合并的表格"),
        localized("Split the merged cells before sorting.", "请先拆分跨行合并的单元格。"), window: window)
      return
    }
    updateTable(sorted, index: selected, name: localized("Sort table", "排序表格"), reload: false)
    tableView.reloadData()
  }
  private func copyTable() {
    window?.makeFirstResponder(nil)
    guard tables.indices.contains(selected) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(tables[selected].delimited(separator: "\t"), forType: .string)
  }
  private func saveTable(excel: Bool) {
    window?.makeFirstResponder(nil)
    guard let window, tables.indices.contains(selected) else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = localized("Recognized table", "识别的表格") + (excel ? ".xlsx" : ".csv")
    panel.allowedContentTypes = [excel ? UTType(filenameExtension: "xlsx")! : .commaSeparatedText]
    let fillMerged = NSButton(checkboxWithTitle: localized("Fill merged cells", "填充合并单元格"), target: nil, action: nil)
    if !excel, tables[selected].hasMergedCells {
      fillMerged.toolTip = localized("CSV has no merged cells; repeat their content in each cell.", "CSV 不支持合并单元格，可将内容填入每一格。")
      panel.accessoryView = fillMerged
    }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self, self.tables.indices.contains(self.selected) else { return }
      let table = self.tables[self.selected]
      let fill = fillMerged.state == .on
      Task { [weak self] in
        do {
          let data = try await Task.detached(priority: .userInitiated) {
            try excel ? TableExport.xlsx(table) : Data(("\u{feff}" + table.delimited(separator: ",", fillMerged: fill)).utf8)
          }.value
          try data.write(to: url, options: .atomic)
        } catch { warning(localized("Unable to save table", "无法保存表格"), errorMessage(error), window: self?.window) }
      }
    }
  }
  func windowWillClose(_ notification: Notification) {
    closed = true
    task?.cancel()
    onClose?(self)
  }
}
