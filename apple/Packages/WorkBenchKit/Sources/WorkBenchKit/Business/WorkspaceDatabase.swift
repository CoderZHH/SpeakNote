import Foundation

public actor WorkspaceDatabase {
  private let engine: WorkspaceEngine
  public let url: URL
  public init(url: URL) throws {
    self.url = url
    engine = try WorkspaceEngine(url: url)
  }
  public func snapshot() throws -> WorkspaceSnapshot { try engine.snapshot() }
  @discardableResult public func perform(_ command: WorkspaceCommand, now: Date = .now) throws
    -> CommandResult
  { try engine.perform(command, now: now) }
  public func pendingDocuments() throws -> [SyncDocument] { try engine.pendingDocuments() }
  public func receive(_ documents: [SyncDocument]) throws { try engine.receive(documents) }
  public func acknowledge(_ document: SyncDocument, serverFields: String) throws {
    try engine.acknowledge(document, serverFields: serverFields)
  }
  public func bindCloud(container: String, account: String) throws {
    try engine.bindCloud(container: container, account: account)
  }
  public func syncSetting(_ key: String) throws -> JSONValue { try engine.syncSetting(key) }
  public func setSyncSetting(_ key: String, value: JSONValue) throws {
    try engine.setSyncSetting(key, value)
  }
  public func backup(to url: URL) throws { try engine.db.backup(to: url) }
}
final class WorkspaceEngine {
  let db: SQLite
  var assistantInstalled = false
  init(url: URL) throws {
    db = try SQLite(url)
    try WorkspaceMigration.run(db)
    try installJournal()
  }
  func snapshot() throws -> WorkspaceSnapshot {
    var result = WorkspaceSnapshot()
    for entity in WorkspaceEntity.allCases {
      result.items[entity] = try db.rows("SELECT * FROM \(quote(entity.rawValue))").map {
        WorkspaceItem(entity: entity, fields: $0)
      }
    }
    result.pending = Int(
      try db.one("SELECT count(*) AS n FROM wb_sync_meta WHERE dirty=1").integer("n"))
    result.conflicts = try db.rows("SELECT * FROM wb_sync_conflicts ORDER BY created_at DESC").map {
      SyncConflict(
        id: $0.identifier, entity: $0.text("entity"), recordID: $0.text("record_id"),
        local: (try? JSONValue(json: $0.text("payload"))) ?? .string($0.text("payload")),
        remote: try conflictCurrent(entity: $0.text("entity"), recordID: $0.text("record_id")),
        revision: try conflictRevision(entity: $0.text("entity"), recordID: $0.text("record_id")),
        base: (try? JSONValue(json: $0.text("base_payload"))) ?? .null)
    }
    return result
  }
  func exists(_ entity: WorkspaceEntity, _ id: String) throws -> Record {
    let row = try db.record(entity.rawValue, id: id)
    try require(!row.isEmpty, "记录已不存在，请刷新后重试")
    return row
  }
  func association(_ fields: Record) throws {
    let associations: [(String, WorkspaceEntity)] = [
      ("project_id", .projects), ("learning_id", .learning), ("course_id", .courses),
    ]
    try require(associations.filter { !fields[value: $0.0].isNull }.count <= 1, "只能关联一个项目、学习或课程")
    for (field, entity) in associations where !fields[value: field].isNull {
      _ = try exists(entity, fields.text(field))
    }
  }
  func perform(_ command: WorkspaceCommand, now: Date) throws -> CommandResult {
    try db.transaction {
      let stamp = JSONValue.string(Clock.stamp(now))
      switch command {
      case .create(let entity, let id, let input):
        var fields = Dictionary(uniqueKeysWithValues: input.map { ($0.key.rawValue, $0.value) })
        fields["id"] = .string(id)
        switch entity {
        case .tasks:
          fields["created_at"] = stamp
          fields["updated_at"] = stamp
          if fields["planned_date"] == nil { fields["planned_date"] = .string(Clock.day(now)) }
          if fields["status"] == .string("done") { fields["completed_at"] = stamp }
          if fields["status"] == .string("abandoned") { fields["abandoned_at"] = stamp }
        case .notes, .projects, .learning, .courses, .semesters, .courseMeetings, .accounts:
          fields["created_at"] = stamp
          if [.projects, .learning, .courses].contains(entity), fields["status"] == .string("done") {
            fields["completed_at"] = stamp
          }
          if entity == .learning {
            fields["position"] = .integer(
              try db.one("SELECT COALESCE(MAX(position),-1)+1 AS n FROM learning").integer("n"))
          }
        case .reflections:
          fields["created_at"] = stamp
          fields["updated_at"] = stamp
          if fields["day"] == nil { fields["day"] = .string(Clock.day(now)) }
        case .lessons:
          let learning = try exists(.learning, fields.text("learning_id"))
          if !fields[value: "parent_id"].isNull {
            try require(
              try exists(.lessons, fields.text("parent_id")).text("learning_id")
                == learning.identifier, "阶段必须属于同一学习项")
          }
          fields["position"] = .integer(
            try db.one(
              "SELECT COALESCE(MAX(position),-1)+1 AS n FROM lessons WHERE learning_id=? AND parent_id IS ?",
              [learning[value: "id"], fields[value: "parent_id"]]
            ).integer("n"))
        default: throw WorkBenchError("请通过对应服务创建此记录")
        }
        fields = try validate(entity, fields, creating: true)
        try db.insert(entity.rawValue, fields)
        return CommandResult(
          id: id, thoughtVersion: entity == .reflections ? .init(fields: fields) : nil)
      case .update(let entity, let id, let input, let expected, let thought):
        let old = try exists(entity, id)
        if let expected { try require(old.text("updated_at") == expected, "内容已变化，请重新打开后修改") }
        if thought != nil { try require(entity == .reflections, "正文版本只适用于思考") }
        var patch = Dictionary(uniqueKeysWithValues: input.map { ($0.key.rawValue, $0.value) })
        if [.tasks, .reflections].contains(entity) {
          let previous = try? Clock.parse(old.text("updated_at"))
          patch["updated_at"] = .string(
            Clock.stamp(max(now, previous?.addingTimeInterval(0.001) ?? now)))
        }
        if [.tasks, .projects, .learning, .courses].contains(entity), let status = patch["status"] {
          patch["completed_at"] =
            status == .string("done")
            ? (old.text("status") == "done" && !old[value: "completed_at"].isNull
              ? old[value: "completed_at"] : stamp) : .null
          if entity == .tasks {
            patch["abandoned_at"] =
              status == .string("abandoned")
              ? (old.text("status") == "abandoned" ? old[value: "abandoned_at"] : stamp) : .null
          }
        }
        var merged = old.merging(patch) { _, v in v }
        merged = try validate(entity, merged, creating: false)
        let savedThought: ThoughtContentVersion? =
          entity == .reflections ? .init(fields: merged) : nil
        if let thought {
          let current = ThoughtContentVersion(fields: old)
          guard current == thought || current == savedThought else {
            throw ThoughtSaveConflict(saved: current)
          }
        }
        if old.filter({ $0.key != "updated_at" }) == merged.filter({ $0.key != "updated_at" }) {
          return CommandResult(id: id, thoughtVersion: savedThought)
        }
        patch = Dictionary(
          uniqueKeysWithValues: Set(patch.keys).union([
            "importance", "priority", "important", "start_time", "end_time", "reminder_enabled", "reminder_at",
          ]).compactMap { key in merged[key].map { (key, $0) } })
        try db.update(entity.rawValue, id: id, patch)
        if entity == .semesters || entity == .courses {
          let meetings = try db.rows(
            entity == .semesters
              ? "SELECT m.* FROM course_meetings m JOIN courses c ON c.id=m.course_id WHERE c.semester_id=?"
              : "SELECT * FROM course_meetings WHERE course_id=?", [.string(id)])
          for var meeting in meetings { try validateCourse(.courseMeetings, &meeting) }
        }
        if entity == .tasks {
          if merged.text("status") != "todo" {
            for focus in try db.rows(
              "SELECT * FROM focus_sessions WHERE task_id=? AND status!='ended'", [.string(id)])
            { try finishFocus(focus, now: now) }
          }
          try db.execute(
            "UPDATE lessons SET done=? WHERE task_id=?",
            [.integer(merged.text("status") == "done" ? 1 : 0), .string(id)])
          try db.execute(
            "UPDATE lessons SET task_id=NULL WHERE task_id=? AND learning_id IS NOT ?",
            [.string(id), merged[value: "learning_id"]])
        }
        if entity == .lessons, !old[value: "task_id"].isNull {
          var changes: Record = [:]
          if let title = patch["title"] { changes["title"] = title }
          if let done = patch["done"] {
            changes["status"] = .string(done.bool ? "done" : "todo")
            changes["completed_at"] = done.bool ? stamp : .null
          }
          changes["updated_at"] = stamp
          try db.update("tasks", id: old.text("task_id"), changes)
        }
        return CommandResult(id: id, thoughtVersion: savedThought)
      case .delete(let entity, let id):
        _ = try exists(entity, id)
        try db.execute("DELETE FROM \(quote(entity.rawValue)) WHERE id=?", [.string(id)])
        return CommandResult(id: id)
      case .scheduleLesson(let id, let plannedDate):
        let lesson = try exists(.lessons, id)
        try require(!lesson[value: "done"].bool, "这一步已经完成")
        let taskID: String
        if !lesson[value: "task_id"].isNull {
          taskID = lesson.text("task_id")
          try db.update(
            "tasks", id: taskID,
            ["planned_date": try Validation.day(.string(plannedDate)), "updated_at": stamp])
        } else {
          taskID = UUID().uuidString.lowercased()
          try db.insert(
            "tasks",
            [
              "id": .string(taskID), "title": lesson[value: "title"],
              "learning_id": lesson[value: "learning_id"],
              "planned_date": try Validation.day(.string(plannedDate)), "created_at": stamp,
              "updated_at": stamp,
            ])
          try db.update("lessons", id: id, ["task_id": .string(taskID)])
        }
        return CommandResult(id: taskID)
      case .convertNote(let id, let plannedDate):
        return try convertNote(id: id, plannedDate: plannedDate, now: now)
      case .startFocus(let taskID): return try startFocus(taskID: taskID, now: now)
      case .pauseFocus:
        try pauseFocus(now: now)
        return CommandResult()
      case .endFocus(let id, let hint):
        let focus = try exists(.focusSessions, id)
        try finishFocus(focus, now: now)
        if let hint, !focus[value: "task_id"].isNull {
          try db.update(
            "tasks", id: focus.text("task_id"),
            [
              "resume_hint": try Validation.text(.string(hint), "接续位置", max: 2000),
              "updated_at": stamp,
            ])
        }
        return CommandResult(id: id)
      case .correctFocus(let id, let intervalID, let start, let end):
        return try correctFocus(id: id, intervalID: intervalID, start: start, end: end, now: now)
      case .importMetrics(let accountID, let rows):
        return try importMetrics(accountID: accountID, rows: rows, now: now)
      case .installTimetable:
        try installTimetable()
        return CommandResult()
      case .move(let entity, let id, let targetEntity, let targetID, let placement):
        try move(
          entity, id: id, targetEntity: targetEntity, targetID: targetID, placement: placement,
          now: now)
        return CommandResult(id: id)
      case .dismissConflict(let id):
        try db.execute("DELETE FROM wb_sync_conflicts WHERE id=?", [.string(id)])
        return CommandResult(id: id)
      case .restoreConflict(let id): return try restoreConflict(id)
      case .resolveConflict(let id, let choice, let revision):
        return try resolveConflict(id, choice: choice, expectedRevision: revision)
      }
    }
  }
  func validate(_ entity: WorkspaceEntity, _ input: Record, creating: Bool, checkAssociations: Bool = true) throws -> Record {
    var f = input
    for (key, max) in [
      ("title", entity == .tasks || entity == .lessons ? 500 : 200), ("content", 20000),
      ("notes", 10000), ("remark", 10000), ("description", 10000), ("resume_hint", 2000),
      ("name", 100), ("teacher", 200), ("code", 200), ("room", 200),
    ] where f[key] != nil {
      f[key] = try Validation.text(
        f[key]!, key, max: max, required: ["title", "content", "name"].contains(key))
    }
    let required: String? =
      switch entity {
      case .tasks, .projects, .learning, .lessons, .courses, .semesters: "title"
      case .notes, .reflections: "content"
      case .accounts: "name"
      default: nil
      }
    if let required { try require(!f.text(required).isEmpty, "请填写名称或内容") }
    if checkAssociations && [.tasks, .notes].contains(entity) { try association(f) }
    if [.tasks, .projects, .learning, .courses, .notes].contains(entity), let status = f["status"] {
      let allowed =
        entity == .tasks
        ? ["todo", "done", "abandoned"]
        : entity == .notes ? ["inbox", "processed", "archived"] : ["active", "paused", "done"]
      try require(allowed.contains(status.string), "状态不正确")
    }
    if entity == .tasks {
      let level =
        f["importance"]
        ?? .integer(f[value: "important"].bool || f["priority"] == .string("high") ? 4 : 1)
      f["importance"] = try Validation.integer(level, 1...5)
      if f["important"] != nil { f["important"] = .integer(f[value: "important"].bool ? 1 : 0) }
      if let priority = f["priority"] {
        try require(["normal", "high"].contains(priority.string), "优先级不正确")
      }
      if let estimate = f["estimate"] { f["estimate"] = try Validation.integer(estimate, 1...480) }
      for key in ["planned_date", "due_date"] where f[key] != nil {
        f[key] = try Validation.day(f[key]!)
      }
      if f[value: "planned_date"].isNull {
        f["start_time"] = .null
        f["end_time"] = .null
      }
      let reminder = f["reminder_enabled"] ?? .integer(0)
      try require(reminder == .integer(0) || reminder == .integer(1), "提醒开关不正确")
      if let fixed = f["reminder_at"], !fixed.isNull {
        let date = try Clock.parse(fixed.string)
        f["reminder_at"] = reminder == .integer(1) ? .string(Clock.stamp(date)) : .null
      }
      let hasTime = !f[value: "start_time"].isNull || !f[value: "reminder_at"].isNull
      f["reminder_enabled"] = hasTime ? reminder : .integer(0)
      let from = f[value: "start_time"]
      let until = f[value: "end_time"]
      if !from.isNull || !until.isNull {
        try require(
          !from.isNull && !until.isNull && timeMinutes(from.string) != nil
            && timeMinutes(until.string) != nil && from.string < until.string, "请填写完整且有效的开始、结束时间")
      }
    }
    if entity == .reflections {
      f["day"] = try Validation.day(f[value: "day"])
      try require(!f[value: "day"].isNull, "请选择日期")
    }
    if [.reflections, .accounts].contains(entity), let tags = f["tags"] {
      f["tags"] = .string(
        try Validation.tags(tags.isString ? (try JSONValue(json: tags.string)) : tags).json())
    }
    if entity == .accounts {
      try require(
        ["douyin", "bilibili", "xiaohongshu", "x", "tiktok", "instagram", "youtube"].contains(
          f.text("platform")), "平台不支持")
    }
    if [.semesters, .courses, .courseMeetings].contains(entity) { try validateCourse(entity, &f) }
    try require(Set(f.keys).isSubset(of: try db.columns(entity.rawValue)), "记录包含不支持的字段")
    return f
  }
  func convertNote(id: String, plannedDate: String?, now: Date) throws -> CommandResult {
    let note = try exists(.notes, id)
    let existing = try db.one(
      "SELECT * FROM tasks WHERE source_note_id=? ORDER BY created_at LIMIT 1", [.string(id)])
    let taskID: String
    if !existing.isEmpty {
      taskID = existing.identifier
      if let plannedDate {
        try db.update(
          "tasks", id: taskID,
          [
            "planned_date": try Validation.day(.string(plannedDate)),
            "updated_at": .string(Clock.stamp(now)),
            "status": .string(
              existing.text("status") == "abandoned" ? "todo" : existing.text("status")),
            "abandoned_at": .null,
          ])
      }
    } else {
      taskID = UUID().uuidString.lowercased()
      let title = String(
        note.text("content").split(separator: "\n").first.map(String.init)?.prefix(200)
          ?? "".prefix(200))
      let content = [note.text("content"), note.text("remark")].filter { !$0.isEmpty }.joined(
        separator: "\n\n")
      try db.insert(
        "tasks",
        [
          "id": .string(taskID), "title": .string(title), "notes": .string(content),
          "source_note_id": .string(id), "project_id": note[value: "project_id"],
          "learning_id": note[value: "learning_id"], "course_id": note[value: "course_id"],
          "planned_date": try Validation.day(
            plannedDate.map(JSONValue.string) ?? .string(Clock.day(now))),
          "created_at": .string(Clock.stamp(now)), "updated_at": .string(Clock.stamp(now)),
        ])
      for var attachment in try db.rows("SELECT * FROM attachments WHERE note_id=?", [.string(id)])
      {
        attachment["id"] = .id()
        attachment["note_id"] = .null
        attachment["task_id"] = .string(taskID)
        try db.insert("attachments", attachment)
      }
    }
    try db.update("notes", id: id, ["status": .string("processed")])
    return CommandResult(id: taskID)
  }
}
extension JSONValue { var isString: Bool { if case .string = self { true } else { false } } }
func timeMinutes(_ s: String) -> Int? {
  let parts = s.split(separator: ":")
  guard s.count == 5, parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
    (0..<24).contains(h), (0..<60).contains(m)
  else { return nil }
  return h * 60 + m
}
extension WorkspaceDatabase {
  func engineImport(data: Data, name: String, owner: MediaOwner) throws -> MediaAttachment {
    let folder = url.deletingLastPathComponent().appendingPathComponent(
      "attachments", isDirectory: true)
    var fields = try MediaFiles.write(
      data, name: name, directory: folder, maximum: 100 * 1024 * 1024, imagesOnly: false)
    fields[owner.field] = .string(owner.id)
    do { try engine.db.insert("attachments", fields) } catch {
      try? MediaFiles.remove(fields.text("file_key"), in: folder)
      throw error
    }
    return MediaAttachment(fields: fields)
  }
}

extension WorkspaceDatabase {
  func assistantReceipt(_ id: String) throws -> JSONValue? {
    try engine.assistantReceipt(id)
  }
  func assistantRecentContext() throws -> JSONValue {
    try engine.assistantRecentContext()
  }
  func applyAssistantChanges(_ changes: JSONValue, requestID: String, attachments: [StagedEntryAttachment]) throws -> JSONValue {
    try engine.applyAssistantChanges(changes, requestID: requestID, attachments: attachments, now: .now)
  }
  func assistantCourseSchedule(_ arguments: JSONValue) throws -> JSONValue {
    try engine.assistantCourseSchedule(arguments)
  }
  func assistantSearch(_ arguments: JSONValue) throws -> JSONValue {
    try engine.assistantSearch(arguments)
  }
  func prepareAssistantPlan(_ changes: JSONValue, source: String, now: Date = .now) throws -> AssistantPreparedPlan {
    try engine.prepareAssistantPlan(changes, source: source, now: now)
  }
  func commitAssistantPlan(id: String, attachments: [StagedEntryAttachment] = [], now: Date = .now) throws -> JSONValue {
    try engine.commitAssistantPlan(id: id, attachments: attachments, now: now)
  }
  func cancelAssistantPlan(id: String) throws {
    try engine.installAssistant()
    try engine.db.execute("UPDATE wb_assistant_plans SET cancelled=1,payload='{}' WHERE id=? AND result IS NULL", [.string(id)])
  }

  public func exportDocument() throws -> JSONValue { try engine.exportDocument() }
  public func importDocument(_ document: JSONValue) throws -> Int {
    try engine.importDocument(document)
  }
}

extension WorkspaceDatabase {
  /// Caller supplies a stable new-entry UUID; retries never duplicate the item or media.
  func saveEntry(
    entity: WorkspaceEntity, id: String, fields: [ItemField: JSONValue],
    attachments: [StagedEntryAttachment], now: Date = .now
  ) throws {
    try require([WorkspaceEntity.tasks, .notes, .projects, .learning].contains(entity), "不支持的创建类型")
    let folder = url.deletingLastPathComponent().appendingPathComponent("attachments")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let owner: MediaOwner =
      entity == .tasks
      ? .task(id)
      : entity == .notes
        ? .note(id)
        : entity == .projects ? .project(id) : .learning(id)
    var copied: [String] = []
    do {
      try engine.db.transaction {
        let existing = try engine.db.record(entity.rawValue, id: id)
        _ = try engine.perform(
          existing.isEmpty
            ? .create(entity, id: id, fields: fields)
            : .update(entity, id: id, fields: fields), now: now)
        for item in attachments {
          var row = item.fields
          let old = try engine.db.record("attachments", id: item.id)
          if !old.isEmpty {
            try require(
              old[owner.field] == .string(id) && old["sha256"] == row["sha256"], "附件归属或内容已变化")
            continue
          }
          try MediaFiles.validate(
            .object(row), directory: item.directory, maximum: 100 * 1024 * 1024)
          let key = row.text("file_key")
          try FileManager.default.copyItem(
            at: item.directory.appendingPathComponent(key), to: folder.appendingPathComponent(key))
          copied.append(key)
          row[owner.field] = .string(id)
          try engine.db.insert("attachments", row)
        }
      }
    } catch {
      for key in copied { try? MediaFiles.remove(key, in: folder) }
      throw error
    }
  }
}
