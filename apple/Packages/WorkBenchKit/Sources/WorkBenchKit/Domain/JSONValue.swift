import Foundation

/// Lossless JSON at the persistence/CloudKit boundary. UI commands never use action strings.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Int64.self) {
      self = .integer(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .integer(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
  public subscript(_ key: String) -> JSONValue {
    get { object[key] ?? .null }
    set {
      var v = object
      v[key] = newValue
      self = .object(v)
    }
  }
  public var object: [String: JSONValue] { if case .object(let v) = self { v } else { [:] } }
  public var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
  public var string: String { if case .string(let v) = self { v } else { "" } }
  public var int: Int64 {
    switch self {
    case .integer(let v): v
    case .bool(let v): v ? 1 : 0
    default: 0
    }
  }
  public var isNull: Bool { self == .null }
  public var bool: Bool { self == .bool(true) || self == .integer(1) }
  public init(data: Data) throws { self = try JSONDecoder().decode(Self.self, from: data) }
  public init(json: String) throws { try self.init(data: Data(json.utf8)) }
  public func data() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
  public func json() throws -> String { String(decoding: try data(), as: UTF8.self) }
  static func id() -> Self { .string(UUID().uuidString.lowercased()) }
}
public typealias Record = [String: JSONValue]
extension Dictionary where Key == String, Value == JSONValue {
  subscript(value key: String) -> JSONValue { self[key] ?? .null }
  func text(_ key: String) -> String { self[key]?.string ?? "" }
  func integer(_ key: String) -> Int64 { self[key]?.int ?? 0 }
  var identifier: String { text("id") }
}
public struct WorkBenchError: LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw WorkBenchError(message) }
}
enum Clock {
  static func stamp(_ date: Date = .now) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = .gmt
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }
  static func parse(_ value: String) throws -> Date {
    if let date = try? Date(
      value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    {
      return date
    }
    if let date = try? Date(value, strategy: .iso8601) { return date }
    throw WorkBenchError("时间格式不正确")
  }
  static var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    c.firstWeekday = 2
    return c
  }
  static func day(_ date: Date = .now) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
}
enum Validation {
  static func text(_ v: JSONValue, _ name: String, max: Int, required: Bool = false) throws
    -> JSONValue
  {
    guard case .string(let s) = v else { throw WorkBenchError("\(name)格式不正确") }
    let value = s.trimmingCharacters(in: .whitespacesAndNewlines)
    try require(
      value.utf16.count <= max && (!required || !value.isEmpty), "请填写有效的\(name)（最多 \(max) 字）")
    return .string(value)
  }
  static func day(_ v: JSONValue) throws -> JSONValue {
    if v.isNull || v == .string("") { return .null }
    let s = v.string
    let f = DateFormatter()
    f.calendar = Clock.calendar
    f.timeZone = Clock.calendar.timeZone
    f.dateFormat = "yyyy-MM-dd"
    f.isLenient = false
    try require(s.count == 10 && f.date(from: s).map { f.string(from: $0) == s } == true, "日期格式不正确")
    return v
  }
  static func integer(_ v: JSONValue, _ range: ClosedRange<Int64>) throws -> JSONValue {
    guard case .integer(let n) = v, range.contains(n) else { throw WorkBenchError("数值超出范围") }
    return v
  }
  static func tags(_ v: JSONValue) throws -> JSONValue {
    guard case .array(let values) = v, values.count <= 8 else { throw WorkBenchError("最多 8 个标签") }
    var tags: [JSONValue] = []
    for value in values {
      let s = try text(value, "标签", max: 30, required: true).string
        .precomposedStringWithCanonicalMapping
      try require(
        !s.contains(where: {
          ",，;；、".contains($0)
            || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }), "标签不能含分隔符")
      if !tags.contains(.string(s)) { tags.append(.string(s)) }
    }
    return .array(tags)
  }
}
