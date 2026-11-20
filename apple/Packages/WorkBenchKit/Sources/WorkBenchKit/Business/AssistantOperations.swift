import Foundation

/// Validated changes and version preconditions shared by both execution paths.
struct AssistantPreparedPlan: Codable, Sendable, Identifiable {
  let id: String
  let changes: [AssistantPreparedChange]
  let expiresAt: String

  func preview() throws -> JSONValue {
    let names = [
      "title": "名称", "content": "内容", "notes": "备注", "remark": "备注", "status": "状态",
      "planned_date": "计划日期", "due_date": "截止日期", "start_time": "开始", "end_time": "结束",
      "importance": "重要程度", "space_id": "空间", "collection_id": "卡片",
      "semester_id": "学期", "first_monday": "第一周周一", "weeks": "周数",
      "teacher": "教师", "code": "班号", "room": "教室",
      "weekday": "星期", "period_start": "起始节", "period_end": "结束节",
      "course_id": "课程", "project_id": "项目", "learning_id": "学习",
    ]
    let states = ["todo": "待办", "done": "已完成", "abandoned": "放弃", "inbox": "收件箱",
      "processed": "已处理", "archived": "归档"]
    let lines = changes.map { change in
      let target = ["update", "forget"].contains(change.kind) ? "：\(change.title)" : ""
      let fields = change.fields.keys.sorted().compactMap { key -> String? in
        guard let name = names[key], let value = change.fields[key] else { return nil }
        let display: String
        if value.isNull { display = "清空" }
        else if let title = change.associationNames?[key] { display = title }
        else if case .integer(let number) = value { display = String(number) }
        else if key == "status" { display = states[value.string] ?? value.string }
        else { display = value.string }
        return "  \(name)：\(display)"
      }
      return (["• \(change.label)\(target)"] + fields).joined(separator: "\n")
    }.joined(separator: "\n")
    try require(lines.utf16.count <= 1500, "变更内容太长，无法完整展示，请分批操作")
    return .object(["id": .string(id), "text": .string(lines), "expires_at": .string(expiresAt)])
  }
}

struct AssistantPreparedChange: Codable, Sendable, Identifiable {
  let id: String
  let kind: String
  let entity: String
  let targetID: String
  let fields: Record
  let before: Record
  let versions: [String: String]
  let associationNames: [String: String]?
  let attachImage: Bool?

  var mediaOwner: MediaOwner? {
    switch entity {
    case "tasks": .task(targetID)
    case "notes": .note(targetID)
    case "projects": .project(targetID)
    case "learning": .learning(targetID)
    case "collections": .collection(targetID)
    default: nil
    }
  }

  var title: String {
    let title = before.text("title").isEmpty ? before.text("content") : before.text("title")
    return String(title.prefix(160))
  }
  var label: String {
    switch kind {
    case "remember": "记住偏好"
    case "forget": "忘记偏好"
    case "delete": "删除" + (AssistantContract.Entity(rawValue: entity)?.label ?? "事项")
    case "start_focus": "开始专注"
    case "create": "新增" + (AssistantContract.Entity(rawValue: entity)?.label ?? "事项")
    default:
      switch fields.text("status") {
      case "done":
        (entity == "courses" ? "结课" : "完成") + (AssistantContract.Entity(rawValue: entity)?.label ?? "事项")
      case "paused": "暂停" + (AssistantContract.Entity(rawValue: entity)?.label ?? "事项")
      case "archived": "归档随手记"
      case "abandoned": "放弃任务"
      default: "更新" + (AssistantContract.Entity(rawValue: entity)?.label ?? "事项")
      }
    }
  }
}

extension WorkspaceEngine {
  func installAssistant() throws {
    guard !assistantInstalled else { return }
    // Local control metadata, like wb_sync_*; never added to WorkspaceEntity/CloudKit.
    try db.script(
      """
      CREATE TABLE IF NOT EXISTS wb_assistant_plans(
        id TEXT PRIMARY KEY,payload TEXT NOT NULL,result TEXT,created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,cancelled INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS wb_assistant_memories(
        id TEXT PRIMARY KEY,content TEXT NOT NULL,source TEXT NOT NULL,created_at TEXT NOT NULL);
      """)
    assistantInstalled = true
  }

  func assistantVersion(_ row: Record) throws -> String {
    MediaFiles.hash(try JSONValue.object(row).data())
  }

  func assistantRecentContext(now: Date = .now) throws -> JSONValue {
    try installAssistant()
    let rows = try db.rows(
      "SELECT result FROM wb_assistant_plans WHERE result IS NOT NULL AND created_at>? ORDER BY created_at DESC,rowid DESC LIMIT 30",
      [.string(Clock.stamp(now.addingTimeInterval(-1800)))])
    var seen = Set<String>()
    var items: [JSONValue] = []
    for row in rows {
      let result = try JSONValue(json: row.text("result"))
      for item in result["items"].array.reversed() {
        var entity = item["entity"].string
        var id = item["id"].string
        if entity == "focus_sessions" {
          let focus = try db.record("focus_sessions", id: id)
          entity = "tasks"
          id = focus.text("task_id")
        }
        guard [
          "spaces", "collections", "semesters", "courses", "course_meetings",
          "tasks", "notes", "projects", "learning",
        ].contains(entity) else { continue }
        guard !id.isEmpty else { continue }
        guard seen.insert(entity + "/" + id).inserted else { continue }
        let current = try assistantRecord(entity: entity, id: id)
        guard !current.isEmpty else { continue }
        var visible = try assistantVisible(current, entity: entity)
        var fields = visible["fields"].object.filter {
          [
            "id", "title", "content", "status", "planned_date", "due_date",
            "first_monday", "weeks", "semester_id", "weekday", "period_start", "period_end", "room",
            "space_id", "collection_id", "course_id", "project_id", "learning_id",
          ].contains($0.key)
        }
        if let content = fields["content"] { fields["content"] = .string(String(content.string.prefix(160))) }
        visible["fields"] = .object(fields)
        items.append(visible)
        if items.count == 5 { return .object(["items": .array(items)]) }
      }
    }
    return .object(["items": .array(items)])
  }

  func assistantRecord(entity: String, id: String) throws -> Record {
    try require(
      AssistantContract.Entity(rawValue: entity) != nil,
      "助手不能访问这类数据")
    return try db.record(entity == "memory" ? "wb_assistant_memories" : entity, id: id)
  }

  func assistantSearch(_ arguments: JSONValue, now: Date = .now) throws -> JSONValue {
    try installAssistant()
    guard let capability = AssistantContract.Entity(rawValue: arguments["entity"].string) else {
      throw WorkBenchError("不支持的查询类型")
    }
    let entity = capability.rawValue
    let query = arguments["query"].string
    try require(query.count <= 500, "查询内容过长")
    let table = entity == "memory" ? "wb_assistant_memories" : entity
    let title = capability.titleColumn
    var predicates: [String] = []
    var values: [JSONValue] = []
    if !query.isEmpty {
      predicates.append("instr(lower(\(quote(title))),lower(?))>0")
      values.append(.string(query))
    }
    for field in [
      "status", "planned_date", "space_id", "collection_id", "semester_id", "course_id", "project_id", "learning_id",
    ] where !arguments[field].isNull {
      try require(try db.columns(table).contains(field), "此类型不支持该筛选")
      predicates.append("\(quote(field))=?")
      values.append(arguments[field])
    }
    let filter = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
    if !arguments["task_view"].isNull {
      try require(capability == .tasks && arguments["task_view"] == .string("today"), "不支持此任务视图")
      let tasks = try db.rows("SELECT * FROM tasks\(filter)", values)
        .map { WorkspaceItem(entity: .tasks, fields: $0) }
      let day = Clock.day(now)
      let outstanding = tasks.filter { isTaskDueForToday($0, day: day) }.sorted(by: taskImportanceOrder)
      let completed = tasksCompleted(on: now, in: tasks)
      return .object([
        "date": .string(day),
        "items": .array(try outstanding.prefix(20).map { try assistantVisible($0.fields, entity: entity, compact: true) }),
        "completed_today": .array(try completed.prefix(20).map { try assistantVisible($0.fields, entity: entity, compact: true) }),
        "total": .integer(Int64(outstanding.count)), "completed_total": .integer(Int64(completed.count)),
        "has_more": .bool(outstanding.count > 20), "completed_has_more": .bool(completed.count > 20),
      ])
    }
    let rows = try db.rows(
      "SELECT * FROM \(quote(table))\(filter) ORDER BY created_at DESC,id LIMIT 21", values)
    return .object([
      "items": .array(try rows.prefix(20).map { try assistantVisible($0, entity: entity) }),
      "has_more": .bool(rows.count > 20),
    ])
  }

  func assistantVisible(_ row: Record, entity: String, compact: Bool = false) throws -> JSONValue {
    try require(!row.isEmpty, "事项已不存在，请重新查询")
    let allowed: Set<String> = [
      "id", "title", "content", "notes", "remark", "status", "planned_date", "due_date",
      "start_time", "end_time", "importance", "space_id", "collection_id", "symbol", "color",
      "legacy_entity", "course_id", "project_id", "learning_id",
      "teacher", "code", "semester_id", "first_monday", "weeks", "periods",
      "weekday", "period_start", "period_end", "room",
      "created_at", "completed_at", "description", "reminder_enabled", "reminder_at",
    ]
    let longText: Set<String> = ["content", "notes", "remark", "description"]
    var fields = row.filter { allowed.contains($0.key) && (!compact || !longText.contains($0.key)) }
    var truncated: [JSONValue] = []
    for (key, value) in fields where value.string.count > 3000 {
      fields[key] = .string(String(value.string.prefix(3000)))
      truncated.append(.string(key))
    }
    return .object([
      "entity": .string(entity), "fields": .object(fields),
      "version": .string(try assistantVersion(row)), "truncated_fields": .array(truncated),
    ])
  }

  func assistantReceipt(_ id: String) throws -> JSONValue? {
    try installAssistant()
    let row = try db.record("wb_assistant_plans", id: id)
    return row[value: "result"].isNull ? nil : try JSONValue(json: row.text("result"))
  }

  func applyAssistantChanges(
    _ changes: JSONValue, requestID: String, attachments: [StagedEntryAttachment], now: Date
  ) throws -> JSONValue {
    if let receipt = try assistantReceipt(requestID) { return receipt }
    let stored = try db.record("wb_assistant_plans", id: requestID)
    let expires = (try? Clock.parse(stored.text("expires_at"))) ?? .distantPast
    if !stored.isEmpty && expires <= now {
      try db.execute("DELETE FROM wb_assistant_plans WHERE id=? AND result IS NULL", [.string(requestID)])
    }
    if try db.record("wb_assistant_plans", id: requestID).isEmpty {
      _ = try prepareAssistantPlan(changes, source: "wechat", now: now, requestID: requestID,
        attachmentAvailable: !attachments.isEmpty)
    }
    return try commitAssistantPlan(id: requestID, attachments: attachments, now: now)
  }

  func prepareAssistantPlan(
    _ input: JSONValue, source: String, now: Date, requestID: String? = nil,
    attachmentAvailable: Bool = false
  ) throws -> AssistantPreparedPlan {
    try installAssistant()
    try db.execute(
      "DELETE FROM wb_assistant_plans WHERE (expires_at<=? AND result IS NULL) OR created_at<=?",
      [.string(Clock.stamp(now)), .string(Clock.stamp(now.addingTimeInterval(-7 * 86400)))])
    guard case .array(let requests) = input, (1...10).contains(requests.count) else {
      throw WorkBenchError("每次请提供 1–10 项变更")
    }

    let taskAssociationTypes: [String: AssistantContract.Entity] = [
      "course_id": .courses, "project_id": .projects,
      "learning_id": .learning, "collection_id": .collections,
    ]
    let taskAssociationKeys = Array(taskAssociationTypes.keys)
    var changes: [AssistantPreparedChange] = []
    var targets = Set<String>()
    var references: [String: (AssistantContract.Entity, String)] = [:]

    func resolve(_ value: String, for entity: AssistantContract.Entity) throws -> String {
      guard value.hasPrefix("@") else { return value }
      guard let (kind, id) = references[String(value.dropFirst())], kind == entity else {
        throw WorkBenchError("批内引用不存在或类型不匹配")
      }
      return id
    }

    for original in requests {
      let request = original["kind"] == .string("remind_course")
        ? try assistantCourseReminder(original, now: now) : original
      guard let action = AssistantContract.Action(rawValue: request["kind"].string),
        let entity = AssistantContract.Entity(rawValue: request["entity"].string), action.allows(entity)
      else { throw WorkBenchError("助手不支持这类变更") }

      let creating = action == .create || action == .remember
      let requestedTarget = request["target_id"].string
      let target = creating ? UUID().uuidString.lowercased() : try resolve(requestedTarget, for: entity)
      let freeFocus = action == .startFocus && target.isEmpty
      try require(freeFocus || !target.isEmpty, "请先选择一个目标")
      if action == .startFocus {
        try require(!changes.contains { $0.kind == "start_focus" }, "一次只能开始一个专注")
      } else {
        try require(targets.insert(entity.rawValue + "/" + target).inserted, "同一请求不能重复变更一个目标")
      }
      let attachImage = request["attach_image"] == .bool(true)
      if attachImage {
        try require((action == .create || action == .update) && attachmentAvailable,
          "请把要保存的图片随文字一起发送")
        try require(!changes.contains { $0.attachImage == true }, "一张图片只能指定一个归属")
      }

      var fields = request["fields"].object
      var before: Record = [:]
      var versions: [String: String] = [:]
      var associationNames: [String: String] = [:]
      if !creating && !freeFocus {
        if requestedTarget.hasPrefix("@") {
          try require(action == .startFocus, "请把新建事项的属性直接写入新建操作")
          before = changes.first { $0.targetID == target }?.fields ?? [:]
        } else {
          before = try assistantRecord(entity: entity.rawValue, id: target)
          try require(!before.isEmpty, "事项已不存在，请重新查询")
          let version = try assistantVersion(before)
          try require(request["expected_version"] == .string(version), "内容已变化，请重新查询")
          versions[entity.rawValue + "/" + target] = version
        }
      }

      if let error = AssistantContract.writableFieldError(in: request) {
        throw WorkBenchError(error)
      }
      switch action {
      case .remember:
        let content = try Validation.text(fields[value: "content"], "偏好", max: 1000, required: true)
        fields = ["content": content, "source": .string(String(source.prefix(2000)))]
      case .forget, .startFocus, .delete:
        try require(fields.isEmpty && !attachImage, "此操作不接受字段修改")
      case .create, .update:
        try require(!fields.isEmpty || (action == .update && attachImage), "请提供要修改的内容")
        var deferredAssociation = false
        if entity == .collections, let rawSpace = fields["space_id"], !rawSpace.isNull {
          let spaceKey = try resolve(rawSpace.string, for: .spaces)
          try require(!spaceKey.isEmpty, "关联空间无效")
          fields["space_id"] = .string(spaceKey)
          if rawSpace.string.hasPrefix("@") {
            deferredAssociation = true
            associationNames["space_id"] = changes.first { $0.targetID == spaceKey }?.fields.text("title")
          } else {
            let row = try assistantRecord(entity: "spaces", id: spaceKey)
            try require(!row.isEmpty, "关联空间已不存在")
            versions["spaces/" + spaceKey] = try assistantVersion(row)
            associationNames["space_id"] = row.text("title")
          }
        }
        if entity == .courses, let rawSemester = fields["semester_id"], !rawSemester.isNull {
          let semKey = try resolve(rawSemester.string, for: .semesters)
          try require(!semKey.isEmpty, "关联学期无效")
          fields["semester_id"] = .string(semKey)
          if rawSemester.string.hasPrefix("@") {
            deferredAssociation = true
            associationNames["semester_id"] = changes.first { $0.targetID == semKey }?.fields.text("title")
          } else {
            let row = try assistantRecord(entity: "semesters", id: semKey)
            try require(!row.isEmpty, "关联学期已不存在")
            versions["semesters/" + semKey] = try assistantVersion(row)
            associationNames["semester_id"] = row.text("title")
          }
        }
        if entity == .courseMeetings, let rawCourse = fields["course_id"], !rawCourse.isNull {
          let courseKey = try resolve(rawCourse.string, for: .courses)
          try require(!courseKey.isEmpty, "关联课程无效")
          fields["course_id"] = .string(courseKey)
          if rawCourse.string.hasPrefix("@") {
            deferredAssociation = true
            associationNames["course_id"] = changes.first { $0.targetID == courseKey }?.fields.text("title")
          } else {
            let row = try assistantRecord(entity: "courses", id: courseKey)
            try require(!row.isEmpty, "关联课程已不存在")
            versions["courses/" + courseKey] = try assistantVersion(row)
            associationNames["course_id"] = row.text("title")
          }
        }
        if [.tasks, .notes].contains(entity), !Set(fields.keys).isDisjoint(with: taskAssociationTypes.keys) {
          for (field, parent) in taskAssociationTypes {
            let value = fields[value: field]
            if value.isNull { fields[field] = .null; continue }
            let key = try resolve(value.string, for: parent)
            try require(!key.isEmpty, "关联对象无效")
            fields[field] = .string(key)
            if value.string.hasPrefix("@") {
              deferredAssociation = true
              associationNames[field] = changes.first { $0.targetID == key }?.fields.text("title")
            } else {
              let row = try assistantRecord(entity: parent.rawValue, id: key)
              try require(!row.isEmpty, "关联对象已不存在")
              versions[parent.rawValue + "/" + key] = try assistantVersion(row)
              associationNames[field] = row.text("title")
            }
          }
        }

        if entity == .tasks {
          if creating && fields["planned_date"] == nil { fields["planned_date"] = .string(Clock.day(now)) }
          if !fields[value: "reminder_at"].isNull && fields["reminder_enabled"] == nil {
            fields["reminder_enabled"] = .bool(true)
          }
          if let reminder = fields["reminder_enabled"] {
            guard case .bool(let enabled) = reminder else { throw WorkBenchError("提醒开关需为布尔值") }
            fields["reminder_enabled"] = .integer(enabled ? 1 : 0)
          }
          if let start = fields["start_time"], !start.isNull,
            fields["end_time"] == nil, before[value: "end_time"].isNull,
            let minutes = timeMinutes(start.string), minutes < 1439
          {
            fields["end_time"] = .string(String(format: "%02d:%02d", (minutes + 1) / 60, (minutes + 1) % 60))
          }
        }

        let type = WorkspaceEntity(rawValue: entity.rawValue)!
        let candidate = before.merging(fields) { _, new in new }
        let normalized = try validate(type, candidate, creating: creating, checkAssociations: !deferredAssociation)
        if deferredAssociation && [.tasks, .notes].contains(type) {
          try require(taskAssociationKeys.filter { !candidate[value: $0].isNull }.count <= 1,
            "只能关联一个空间卡片、项目、学习或课程")
        }
        if type == .collections {
          try require(!candidate.text("space_id").isEmpty, "请指定卡片所属的空间")
        }
        if type == .courses {
          try require(!candidate.text("semester_id").isEmpty, "请指定课程所属的学期")
        }
        if type == .courseMeetings {
          try require(!candidate.text("course_id").isEmpty, "请指定排课所属的课程")
        }
        if fields["reminder_enabled"] == .integer(1) {
          try require(normalized["reminder_enabled"] == .integer(1) && normalized[value: "status"] != .string("done")
            && normalized[value: "status"] != .string("abandoned"), "请为待办提供明确的提醒日期和时间")
        }
        if normalized[value: "reminder_enabled"].bool,
          ["planned_date", "start_time", "end_time", "reminder_enabled", "reminder_at"].contains(where: { fields[$0] != nil })
        {
          let at = try normalized[value: "reminder_at"].isNull
            ? Clock.parse(normalized.text("planned_date") + "T" + normalized.text("start_time") + ":00+08:00")
            : Clock.parse(normalized.text("reminder_at"))
          try require(at > now, "提醒时间已过，请提供未来时间")
        }
        for key in Array(fields.keys) { fields[key] = normalized[key] }
      case .remindCourse:
        throw WorkBenchError("请先查询课程安排")
      }

      let reference = request["ref"].string
      if !reference.isEmpty {
        try require(creating && entity.canWriteRecord && references[reference] == nil
          && reference.range(of: "^[A-Za-z][A-Za-z0-9_]{0,31}$", options: .regularExpression) != nil,
          "新建事项的批内别名无效或重复")
        references[reference] = (entity, target)
      }
      changes.append(.init(
        id: UUID().uuidString.lowercased(), kind: action.rawValue, entity: entity.rawValue,
        targetID: target, fields: fields, before: before.filter { ["title", "content"].contains($0.key) },
        versions: versions, associationNames: associationNames, attachImage: attachImage))
    }
    let plan = AssistantPreparedPlan(
      id: requestID ?? UUID().uuidString.lowercased(), changes: changes,
      expiresAt: Clock.stamp(now.addingTimeInterval(600)))
    if requestID == nil { _ = try plan.preview() }
    let payload = try JSONValue(data: JSONEncoder().encode(plan)).json()
    try db.execute(
      "INSERT INTO wb_assistant_plans(id,payload,created_at,expires_at) VALUES(?,?,?,?)",
      [.string(plan.id), .string(payload), .string(Clock.stamp(now)), .string(plan.expiresAt)])
    return plan
  }

  func commitAssistantPlan(id: String, attachments: [StagedEntryAttachment] = [], now: Date) throws
    -> JSONValue
  {
    try installAssistant()
    var copied: [String] = []
    let folder = db.url.deletingLastPathComponent().appendingPathComponent("attachments")
    do {
      return try db.transaction {
        let stored = try db.record("wb_assistant_plans", id: id)
        try require(!stored.isEmpty && stored.integer("cancelled") == 0, "该操作已取消或不存在")
        if !stored[value: "result"].isNull { return try JSONValue(json: stored.text("result")) }
        try require(try Clock.parse(stored.text("expires_at")) > now, "操作预览已过期，请重新准备")
        let plan = try JSONDecoder().decode(
          AssistantPreparedPlan.self, from: Data(stored.text("payload").utf8))
        let replaceID = plan.changes.first(where: { $0.entity == "semesters" && $0.kind == "delete" })?.targetID
        if let semester = plan.changes.first(where: { $0.entity == "semesters" && $0.kind == "create" }) {
          try requireNewSemester(semester.fields, ignoringID: replaceID)
        }
        for change in plan.changes {
          for (key, expected) in change.versions {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            let row = try assistantRecord(entity: parts[0], id: parts[1])
            try require(!row.isEmpty && (try assistantVersion(row)) == expected, "内容或关联已变化，请重新准备操作")
          }
        }
        var items: [JSONValue] = []
        for change in plan.changes {
          var savedID = change.targetID
          switch change.kind {
          case "remember":
            try require(
              try db.one("SELECT count(*) AS n FROM wb_assistant_memories").integer("n") < 100,
              "最多保留 100 条偏好")
            try db.insert(
              "wb_assistant_memories",
              change.fields.merging([
                "id": .string(change.targetID), "created_at": .string(Clock.stamp(now)),
              ]) { _, value in value })
          case "forget":
            try db.execute(
              "DELETE FROM wb_assistant_memories WHERE id=?", [.string(change.targetID)])
          case "start_focus":
            let taskID = change.targetID.isEmpty ? nil : change.targetID
            savedID = try perform(.startFocus(taskID: taskID), now: now).id ?? ""
          case "delete":
            let entity = WorkspaceEntity(rawValue: change.entity)!
            _ = try perform(.delete(entity, id: change.targetID), now: now)
          default:
            let entity = WorkspaceEntity(rawValue: change.entity)!
            var fields: [ItemField: JSONValue] = [:]
            for (key, value) in change.fields {
              guard let field = ItemField(rawValue: key) else { throw WorkBenchError("不支持的字段") }
              fields[field] = value
            }
            if !fields.isEmpty {
              _ = try perform(
                change.kind == "create"
                  ? .create(entity, id: change.targetID, fields: fields)
                  : .update(entity, id: change.targetID, fields: fields), now: now)
            }
          }
          let newTitle = change.fields.text("title").isEmpty ? change.fields.text("content") : change.fields.text("title")
          let title = change.entity == "memory" ? "" : (newTitle.isEmpty ? change.title : String(newTitle.prefix(100)))
          var details = title.isEmpty ? change.label : "\(change.label)「\(title)」"
          if let names = change.associationNames, !names.isEmpty {
            details += "（" + names.values.sorted().joined(separator: "、") + "）"
          }
          if let day = change.fields["planned_date"], !day.isNull {
            details += "，安排 \(day.string)"
            if let start = change.fields["start_time"], !start.isNull { details += " \(start.string)" }
          }
          if let due = change.fields["due_date"], !due.isNull { details += "，\(due.string) 截止" }
          if let at = try? Clock.parse(change.fields.text("reminder_at")) {
            details += "，\(Clock.day(at)) \(TaskScheduleValues.time(at)) 提醒"
          } else if change.fields["reminder_enabled"] == .integer(1) {
            details += "，已保存提醒设置"
          }
          if change.attachImage == true { details += "，已附图片" }
          items.append(.object([
            "entity": .string(change.kind == "start_focus" ? "focus_sessions" : change.entity),
            "id": .string(savedID), "kind": .string(change.kind), "summary": .string(details),
          ]))
        }
        let attachmentOwner = plan.changes.first { $0.attachImage == true }
          ?? (UUID(uuidString: id) == nil ? nil : plan.changes.first { $0.kind == "create" })
        if plan.changes.contains(where: { $0.attachImage == true }) {
          try require(attachments.count == 1, "缺少这次要保存的图片，请重新发送")
        }
        if !attachments.isEmpty {
          guard let change = attachmentOwner, let owner = change.mediaOwner else {
            throw WorkBenchError("请指定图片要保存到哪个事项")
          }
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          for attachment in attachments {
            try MediaFiles.validate(
              .object(attachment.fields), directory: attachment.directory,
              maximum: 20 * 1024 * 1024)
            let key = attachment.fields.text("file_key")
            try FileManager.default.copyItem(
              at: attachment.directory.appendingPathComponent(key),
              to: folder.appendingPathComponent(key))
            copied.append(key)
            var row = attachment.fields
            row[owner.field] = .string(owner.id)
            try db.insert("attachments", row)
          }
        }
        let result: JSONValue = .object([
          "operation_id": .string(id), "status": .string("succeeded"),
          "items": .array(items),
        ])
        // Keep only the idempotent receipt after commit. Old proposals must not retain forgotten preferences.
        try db.execute(
          "UPDATE wb_assistant_plans SET result=?,payload='{}' WHERE id=?",
          [.string(try result.json()), .string(id)])
        return result
      }
    } catch {
      for key in copied { try? MediaFiles.remove(key, in: folder) }
      throw error
    }
  }
}
