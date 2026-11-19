import Foundation

extension WorkspaceEngine {
  func conflictRevision(entity: String, recordID: String) throws -> Int64 {
    try db.one("SELECT revision FROM wb_sync_meta WHERE entity=? AND id=?",
      [.string(entity), .string(recordID)]).integer("revision")
  }

  func conflictCurrent(entity: String, recordID: String) throws -> JSONValue {
    guard WorkspaceEntity(rawValue: entity) != nil else { return .null }
    let fields = try db.record(entity, id: recordID)
    return fields.isEmpty ? .null : .object(fields)
  }

  func preserveConflict(entity: String, recordID: String, payload: JSONValue, base: JSONValue = .null) throws {
    guard !payload.isNull else { return }
    let existing = try db.rows("SELECT payload FROM wb_sync_conflicts WHERE entity=? AND record_id=?",
      [.string(entity), .string(recordID)])
    if existing.contains(where: { row in
      guard let previous = try? JSONValue(json: row.text("payload")) else { return false }
      return RecordMerge.equivalentWorkspace(previous, payload)
    }) {
      return
    }
    try db.insert("wb_sync_conflicts", ["id": .id(), "entity": .string(entity),
      "record_id": .string(recordID), "payload": .string(try payload.json()),
      "base_payload": base.isNull ? .null : .string(try base.json()),
      "created_at": .string(Clock.stamp())])
  }

  // Never deduplicate different record IDs by their titles; equal titles can be intentional.
  func reconcileConflicts() throws {
    try db.transaction {
      var seen: [String: Set<JSONValue>] = [:]
      for row in try db.rows("SELECT * FROM wb_sync_conflicts ORDER BY created_at,id") {
        guard WorkspaceEntity(rawValue: row.text("entity")) != nil,
          let saved = try? JSONValue(json: row.text("payload")), case .object = saved else { continue }
        let current = try conflictCurrent(entity: row.text("entity"), recordID: row.text("record_id"))
        let key = row.text("entity") + ":" + row.text("record_id")
        let content = RecordMerge.workspaceContent(saved)
        if RecordMerge.equivalentWorkspace(saved, current)
          || seen[key, default: []].contains(content)
        {
          try db.execute("DELETE FROM wb_sync_conflicts WHERE id=?", [row[value: "id"]])
        } else { seen[key, default: []].insert(content) }
      }
    }
  }

  func resolveConflict(_ id: String, choice: WorkspaceConflictChoice, expectedRevision: Int64) throws -> CommandResult {
    try db.transaction {
      let row = try db.record("wb_sync_conflicts", id: id)
      // A repeated confirmation after a successful commit is a harmless no-op.
      if row.isEmpty { return CommandResult() }
      if choice == .current {
        try require(try conflictRevision(entity: row.text("entity"), recordID: row.text("record_id")) == expectedRevision,
          "记录刚刚更新，请查看刷新后的比较内容再选择。")
        try db.execute("DELETE FROM wb_sync_conflicts WHERE id=?", [.string(id)])
        return CommandResult(id: row.text("record_id"))
      }
      guard let entity = WorkspaceEntity(rawValue: row.text("entity")) else {
        throw WorkBenchError("这份旧版本可先导出保留内容，再复制到新的记录中。")
      }
      let recordID = row.text("record_id")
      try require(try conflictRevision(entity: entity.rawValue, recordID: recordID) == expectedRevision,
        "记录刚刚更新，请查看刷新后的比较内容再选择。")
      guard let saved = try? JSONValue(json: row.text("payload")), case .object = saved else {
        throw WorkBenchError("这份旧格式内容仍已保留，可直接复制或导出留存。")
      }
      let current = try conflictCurrent(entity: entity.rawValue, recordID: recordID)
      var targetID = recordID
      if choice != .current && !RecordMerge.equivalentWorkspace(saved, current) {
        var resolved = saved
        if choice == .keepBoth && !current.isNull {
          try require(Self.canCopyConflict(entity), "请选择要保留的版本；此记录沿用原有关联。")
          // The conflict UUID is stable across retries, so restoring cannot create a second copy.
          targetID = id
        } else if choice == .saved && !current.isNull {
          let base = (try? JSONValue(json: row.text("base_payload"))) ?? .null
          resolved = RecordMerge.workspace(base: base, local: saved, remote: current,
            preferLocalConflicts: true).0
        }
        var fields = resolved.object
        try require(!fields.isEmpty, "请选择当前版本，或从历史备份中恢复这份内容。")
        fields["id"] = .string(targetID)
        fields.removeValue(forKey: "profile")
        fields.removeValue(forKey: "repo_path")
        if try db.columns(entity.rawValue).contains("updated_at") {
          fields["updated_at"] = .string(Clock.stamp())
        }
        let existing = try db.record(entity.rawValue, id: targetID)
        if choice == .keepBoth && targetID != recordID && !existing.isEmpty {
          try require(RecordMerge.equivalentWorkspace(.object(existing), .object(fields)),
            "已有同名保留记录，请选择使用保留版本或保留当前版本。")
        }
        try validateConflict(entity, fields: &fields, creating: existing.isEmpty)
        if existing.isEmpty { try db.insert(entity.rawValue, fields) }
        else { try db.update(entity.rawValue, id: targetID, fields) }
        if entity == .tasks {
          try db.execute("UPDATE lessons SET done=? WHERE task_id=?",
            [.integer(fields.text("status") == "done" ? 1 : 0), .string(targetID)])
          if fields.text("status") != "todo" {
            for focus in try db.rows("SELECT * FROM focus_sessions WHERE task_id=? AND status!='ended'", [.string(targetID)]) {
              try finishFocus(focus, now: .now)
            }
          }
        }
      }
      try db.execute("DELETE FROM wb_sync_conflicts WHERE id=?", [.string(id)])
      try reconcileConflicts()
      return CommandResult(id: targetID)
    }
  }

  static func canCopyConflict(_ entity: WorkspaceEntity) -> Bool {
    [
      .spaces, .collections, .tasks, .notes, .projects, .learning, .reflections, .accounts,
      .courses, .semesters, .courseMeetings, .lessons,
    ].contains(entity)
  }

  private func validateConflict(_ entity: WorkspaceEntity, fields: inout Record, creating: Bool) throws {
    for (field, parent) in [
      ("space_id", "spaces"), ("collection_id", "collections"),
      ("project_id", "projects"), ("learning_id", "learning"),
      ("course_id", "courses"), ("source_note_id", "notes"), ("semester_id", "semesters"),
      ("task_id", "tasks"), ("note_id", "notes"), ("account_id", "accounts"),
      ("focus_id", "focus_sessions"), ("parent_id", "lessons"),
    ]
    where try !fields[value: field].isNull && db.record(parent, id: fields.text(field)).isEmpty {
      let required =
        entity == .attachments || (entity == .collections && field == "space_id")
        || (entity == .lessons && (field == "learning_id" || field == "collection_id"))
        || (entity == .courseMeetings && field == "course_id")
        || (entity == .focusIntervals && field == "focus_id") || (entity == .metrics && field == "account_id")
      try require(!required, "请先恢复关联的记录，再选择这份版本；保留内容仍在这里。")
      fields[field] = .null
    }
    if [
      .spaces, .collections, .tasks, .notes, .projects, .learning, .reflections, .accounts,
      .courses, .semesters, .courseMeetings,
    ].contains(entity) {
      fields = try validate(entity, fields, creating: creating)
    }
    if entity == .attachments {
      try MediaFiles.validate(.object(fields),
        directory: db.url.deletingLastPathComponent().appendingPathComponent("attachments"),
        maximum: 100 * 1024 * 1024)
    }
    if entity == .focusSessions { try require(fields["status"] == .string("ended"), "请先结束当前专注，再选择保留版本。") }
    if entity == .focusIntervals {
      let start = try Clock.parse(fields.text("started_at")), end = try Clock.parse(fields.text("ended_at"))
      try require(end >= start, "请先修正专注的起止时间，再选择保留版本。")
      for interval in try db.rows("SELECT * FROM focus_intervals WHERE focus_id=? AND id!=? AND ended_at IS NOT NULL",
        [fields[value: "focus_id"], fields[value: "id"]]) {
        try require(try start >= Clock.parse(interval.text("ended_at")) || end <= Clock.parse(interval.text("started_at")),
          "这段专注与当前记录重叠。请先在日历中调整时间，再选择保留版本。")
      }
    }
    try require(Set(fields.keys).isSubset(of: try db.columns(entity.rawValue)), "请更新应用后重新打开这份版本。")
  }
}
