#if os(macOS)
import Foundation

enum TimetableWorkbook {
  static func read(_ data: Data) throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("timetable.xlsx")
    try data.write(to: file)

    func unzip(_ arguments: [String], max: Int) throws -> Data {
      let task = Process()
      let pipe = Pipe()
      task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
      task.arguments = arguments
      task.standardOutput = pipe
      task.standardError = FileHandle.nullDevice
      try task.run()
      var output = Data()
      while let chunk = try pipe.fileHandleForReading.read(upToCount: min(32_768, max + 1 - output.count)),
        !chunk.isEmpty
      {
        output.append(chunk)
        if output.count > max {
          if task.isRunning { task.terminate() }
          task.waitUntilExit()
          throw WorkBenchError("Excel 内容过多，请只保留课表工作表后重试")
        }
      }
      task.waitUntilExit()
      try require(task.terminationStatus == 0, "Excel 文件无法读取，请重新保存为 .xlsx")
      return output
    }
    let entries = String(decoding: try unzip(["-Z1", file.path], max: 65_536), as: UTF8.self)
      .split(separator: "\n").map(String.init)
    let sheets = entries.filter { $0.range(of: #"^xl/worksheets/sheet[0-9]+\.xml$"#,
      options: .regularExpression) != nil }.sorted()
    try require((1...8).contains(sheets.count) && Set(sheets).count == sheets.count,
      "请发包含 1–8 个工作表的 .xlsx")
    var strings: [String] = []
    if entries.contains("xl/sharedStrings.xml") {
      let xml = try unzip(["-p", file.path, "xl/sharedStrings.xml"], max: 512 * 1024)
      let parsed = SheetXML()
      try parsed.read(xml)
      strings = parsed.sharedStrings
    }
    var result: [String] = []
    for sheet in sheets {
      let xml = try unzip(["-p", file.path, sheet], max: 512 * 1024)
      let parsed = SheetXML()
      parsed.references = strings
      try parsed.read(xml)
      if !parsed.rows.isEmpty {
        result.append(sheet.split(separator: "/").last.map(String.init) ?? sheet)
        result.append(contentsOf: parsed.rows)
        if !parsed.mergedRanges.isEmpty {
          result.append("合并单元格：" + parsed.mergedRanges.joined(separator: "、"))
        }
      }
    }
    try require(!result.isEmpty, "Excel 没有可读取的课表单元格")
    let text = result.joined(separator: "\n")
    try require(text.utf8.count <= 24_000, "课表单元格太多，请裁出相关区域或发送截图")
    return text
  }
}

private final class SheetXML: NSObject, XMLParserDelegate {
  var sharedStrings: [String] = []
  var references: [String] = []
  var rows: [String] = []
  var mergedRanges: [String] = []
  private var cells: [String] = []
  private var address = ""
  private var type = ""
  private var value = ""
  private var collecting = false
  private var failed = false

  func read(_ data: Data) throws {
    guard let xml = String(data: data, encoding: .utf8),
      !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else {
      throw WorkBenchError("Excel 工作表使用了不支持的 XML 格式")
    }
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = self
    let parsed = parser.parse()
    try require(parsed && !failed, "Excel 工作表格式异常或内容过多")
  }
  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]) {
    switch name {
    case "si": value = ""
    case "row": cells = []
    case "c":
      address = attributes["r"] ?? ""
      type = attributes["t"] ?? ""
      value = ""
    case "t", "v": collecting = true
    case "mergeCell":
      if let range = attributes["ref"], range.count <= 24 { mergedRanges.append(range) }
      if mergedRanges.count > 1000 { failed = true; parser.abortParsing() }
    default: break
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if collecting { value += string }
    if value.utf8.count > 16_384 { failed = true; parser.abortParsing() }
  }
  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    switch name {
    case "t", "v": collecting = false
    case "si":
      sharedStrings.append(value)
      if sharedStrings.count > 4000 { failed = true; parser.abortParsing() }
    case "c":
      if type == "s" {
        guard let index = Int(value), references.indices.contains(index) else {
          failed = true; parser.abortParsing(); return
        }
        value = references[index]
      }
      if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        cells.append(address + "=" + value.replacingOccurrences(of: "\n", with: " "))
      }
    case "row":
      if !cells.isEmpty { rows.append(cells.joined(separator: " | ")) }
      if rows.count > 500 { failed = true; parser.abortParsing() }
    default: break
    }
  }
}
#endif
