import CSQLite
import Foundation

/// One connection is owned by exactly one store actor. No connection escapes that actor.
final class SQLite {
  private var handle: OpaquePointer?
  let url: URL
  init(_ url: URL, readOnly: Bool = false, useWAL: Bool = true, backupSource: Bool = false) throws {
    self.url = url
    let flags =
      backupSource
      ? SQLITE_OPEN_READWRITE
      : readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
      throw WorkBenchError("数据库无法打开：\(url.lastPathComponent)")
    }
    sqlite3_busy_timeout(handle, 5000)
    if backupSource {
      // A closed WAL database may need its shared-memory sidecar recreated.
      // Allow SQLite to manage sidecars, while prohibiting SQL data writes and
      // never creating a missing source or changing its journal configuration.
      try script("PRAGMA query_only=ON;")
    } else if !readOnly {
      if useWAL { try script("PRAGMA journal_mode=WAL;") }
      try script("PRAGMA foreign_keys=ON;")
    }
  }
  deinit { sqlite3_close(handle) }
  private var error: WorkBenchError { WorkBenchError(String(cString: sqlite3_errmsg(handle))) }
  func script(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error }
  }
  @discardableResult func execute(_ sql: String, _ args: [JSONValue] = []) throws -> Int {
    let statement = try prepare(sql, args)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
    return Int(sqlite3_changes(handle))
  }
  func rows(_ sql: String, _ args: [JSONValue] = []) throws -> [Record] {
    let statement = try prepare(sql, args)
    defer { sqlite3_finalize(statement) }
    var result: [Record] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw error }
      var row: Record = [:]
      for i in 0..<sqlite3_column_count(statement) {
        let key = String(cString: sqlite3_column_name(statement, i))
        switch sqlite3_column_type(statement, i) {
        case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(statement, i))
        case SQLITE_FLOAT: row[key] = .number(sqlite3_column_double(statement, i))
        case SQLITE_TEXT:
          row[key] = .string(
            String(
              decoding: UnsafeBufferPointer(
                start: sqlite3_column_text(statement, i),
                count: Int(sqlite3_column_bytes(statement, i))), as: UTF8.self))
        case SQLITE_NULL: row[key] = .null
        default: throw WorkBenchError("数据库含不支持的二进制字段")
        }
      }
      result.append(row)
    }
    return result
  }
  func one(_ sql: String, _ args: [JSONValue] = []) throws -> Record {
    try rows(sql, args).first ?? [:]
  }
  private func prepare(_ sql: String, _ args: [JSONValue]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw error
    }
    do {
      try require(sqlite3_bind_parameter_count(statement) == args.count, "数据库参数不匹配")
      for (offset, value) in args.enumerated() {
        let index = Int32(offset + 1)
        switch value {
        case .null: sqlite3_bind_null(statement, index)
        case .integer(let n): sqlite3_bind_int64(statement, index, n)
        case .number(let n): sqlite3_bind_double(statement, index, n)
        case .bool(let b): sqlite3_bind_int(statement, index, b ? 1 : 0)
        default:
          let text = if case .string(let s) = value { s } else { try value.json() }
          _ = text.withCString {
            sqlite3_bind_text(
              statement, index, $0, Int32(text.utf8.count),
              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          }
        }
      }
      return statement
    } catch {
      sqlite3_finalize(statement)
      throw error
    }
  }
  func transaction<T>(_ body: () throws -> T) throws -> T {
    if sqlite3_get_autocommit(handle) == 0 {
      let key = "nested_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      try script("SAVEPOINT " + key)
      do {
        let result = try body()
        try script("RELEASE " + key)
        return result
      } catch {
        try? script("ROLLBACK TO " + key + "; RELEASE " + key)
        throw error
      }
    }
    try script("BEGIN IMMEDIATE")
    do {
      let value = try body()
      try script("COMMIT")
      return value
    } catch {
      try? script("ROLLBACK")
      throw error
    }
  }
  func columns(_ table: String) throws -> Set<String> {
    try Set(rows("PRAGMA table_info(\(quote(table)))").map { $0.text("name") })
  }
  func record(_ table: String, id: String) throws -> Record {
    try one("SELECT * FROM \(quote(table)) WHERE id=?", [.string(id)])
  }
  func insert(_ table: String, _ fields: Record) throws {
    let keys = fields.keys.sorted()
    try execute(
      "INSERT INTO \(quote(table))(\(keys.map(quote).joined(separator: ","))) VALUES(\(keys.map { _ in "?" }.joined(separator: ",")))",
      keys.map { fields[$0]! })
  }
  func update(_ table: String, id: String, _ fields: Record) throws {
    let keys = fields.keys.filter { $0 != "id" }.sorted()
    if keys.isEmpty { return }
    try execute(
      "UPDATE \(quote(table)) SET \(keys.map { quote($0) + "=?" }.joined(separator: ",")) WHERE id=?",
      keys.map { fields[$0]! } + [.string(id)])
  }
  func backup(to destination: URL) throws {
    try require(!FileManager.default.fileExists(atPath: destination.path), "备份目标已存在")
    // Backup must be able to adopt the source page size. WAL destinations cannot
    // change page size, and Apple's SQLite default differs from older databases.
    let target = try SQLite(destination, useWAL: false)
    try target.script("PRAGMA journal_mode=DELETE;")
    guard let backup = sqlite3_backup_init(target.handle, "main", handle, "main") else {
      throw target.error
    }
    var result: Int32
    let deadline = Date().addingTimeInterval(10)
    repeat {
      result = sqlite3_backup_step(backup, 256)
      if result == SQLITE_BUSY || result == SQLITE_LOCKED { sqlite3_sleep(20) }
    } while (result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED)
      && Date() < deadline
    let finish = sqlite3_backup_finish(backup)
    try require(
      result == SQLITE_DONE && finish == SQLITE_OK,
      "数据库备份失败（\(result)/\(finish)）：\(target.error.message)（\(sqlite3_extended_errcode(target.handle))/\(sqlite3_system_errno(target.handle))）"
    )
    // Backup copies the source header, which can carry WAL mode with it. Finish
    // in DELETE mode so this is a self-contained snapshot without sidecars.
    try target.script("PRAGMA journal_mode=DELETE;")
    try require(try target.one("PRAGMA integrity_check").values.first == .string("ok"), "备份完整性校验失败")
  }
}
func quote(_ identifier: String) -> String {
  "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
