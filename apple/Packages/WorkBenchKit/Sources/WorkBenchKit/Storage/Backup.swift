import Foundation

extension WorkspaceEngine {
  func exportDocument() throws -> JSONValue {
    try db.transaction {
      var state: Record = [:]
      for entity in WorkspaceEntity.allCases {
        let key =
          entity == .focusSessions
          ? "focus"
          : entity == .focusIntervals
            ? "focusIntervals" : entity == .courseMeetings ? "courseMeetings" : entity.rawValue
        let rows = try db.rows("SELECT * FROM \(quote(entity.rawValue)) ORDER BY id").map {
          row -> JSONValue in
          var fields = row
          for field in ["tags", "periods", "weeks"] where fields[field]?.isString == true {
            fields[field] = try JSONValue(json: fields[field]!.string)
          }
          return .object(fields)
        }
        state[key] = .array(rows)
      }
      state["today"] = .string(Clock.day())
      state["timezone"] = .string("Asia/Shanghai")
      return .object([
        "version": .integer(1), "exportedAt": .string(Clock.stamp()), "state": .object(state),
      ])
    }
  }
  func importDocument(_ document: JSONValue) throws -> Int {
    try require(document["version"].isNull || document["version"] == .integer(1), "备份版本不支持")
    let state = document["state"].isNull ? document : document["state"]
    guard case .object = state else { throw WorkBenchError("备份格式不正确") }
    return try db.transaction {
      try db.script("PRAGMA defer_foreign_keys=ON")
      var count = 0
      for entity in WorkspaceEntity.allCases {
        let key =
          entity == .focusSessions
          ? "focus"
          : entity == .focusIntervals
            ? "focusIntervals" : entity == .courseMeetings ? "courseMeetings" : entity.rawValue
        if state[key].isNull { continue }
        guard case .array(let rows) = state[key] else { throw WorkBenchError("备份格式不正确") }
        for value in rows {
          var fields = value.object
          let id = try Validation.text(value["id"], "记录 ID", max: 100, required: true).string
          if entity == .focusSessions && value["status"] != .string("ended")
            || entity == .focusIntervals && value["ended_at"].isNull
          {
            continue
          }
          if try !db.record(entity.rawValue, id: id).isEmpty { continue }
          if [
            .tasks, .notes, .projects, .learning, .reflections, .accounts, .courses, .semesters,
            .courseMeetings,
          ].contains(entity) {
            fields = try validate(entity, fields, creating: true)
          }
          if entity == .attachments {
            try MediaFiles.validate(
              value,
              directory: db.url.deletingLastPathComponent().appendingPathComponent("attachments"),
              maximum: 100 * 1024 * 1024)
          }
          let columns = try db.columns(entity.rawValue)
          fields = fields.filter { columns.contains($0.key) }
          try db.insert(entity.rawValue, fields)
          count += 1
        }
      }
      try require(try db.rows("PRAGMA foreign_key_check").isEmpty, "备份关联缺少记录")
      return count
    }
  }
}
