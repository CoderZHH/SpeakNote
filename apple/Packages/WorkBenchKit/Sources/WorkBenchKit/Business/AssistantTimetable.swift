import Foundation

extension AssistantPreparedPlan {
  func timetablePreview() throws -> JSONValue {
    guard let semester = changes.first, semester.entity == "semesters" else {
      throw WorkBenchError("找不到待确认的学期")
    }
    let term = semester.fields
    let periods = term["periods"]?.array ?? []
    let courses = changes.filter { $0.entity == "courses" }
    let meetings = Dictionary(grouping: changes.filter { $0.entity == "course_meetings" }) {
      $0.fields.text("course_id")
    }
    var lines = [
      "新建学期「\(term.text("title"))」",
      "第一周周一：\(term.text("first_monday")) · 共 \(term.integer("weeks")) 周",
      "节次：" + periods.map {
        "\($0["number"].int)节 \($0["start"].string)–\($0["end"].string)"
      }.joined(separator: "；"),
    ]
    let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    for course in courses {
      let fields = course.fields
      let details = [fields.text("teacher"), fields.text("code")].filter { !$0.isEmpty }
      lines.append("• " + fields.text("title") + (details.isEmpty ? "" : "（" + details.joined(separator: "、") + "）"))
      for meeting in meetings[course.targetID, default: []] {
        let slot = meeting.fields
        let weekday = weekdays[Int(slot.integer("weekday")) - 1]
        let weeks = slot[value: "weeks"].array.map { String($0.int) }.joined(separator: "、")
        let room = slot.text("room")
        lines.append("  周\(weekday) 第\(slot.integer("period_start"))–\(slot.integer("period_end"))节 · 周次 \(weeks)"
          + (room.isEmpty ? "" : " · " + room))
      }
    }
    let preview = lines.joined(separator: "\n")
    try require(preview.utf16.count <= 3500, "课表过长，微信无法完整预览。请提供更精简的课表。")
    return .object(["id": .string(id), "text": .string(preview), "expires_at": .string(expiresAt)])
  }
}

extension WorkspaceEngine {
  private enum TimetableValidation: Error { case rollback }

  func requireNewSemester(_ fields: Record) throws {
    let existing = try db.one(
      "SELECT id FROM semesters WHERE first_monday=? OR title=? LIMIT 1",
      [.string(fields.text("first_monday")), .string(fields.text("title"))])
    try require(existing.isEmpty, "已有同名或同一天开始的学期，未创建。请先在课程页核对现有学期。")
  }

  func prepareAssistantTimetable(_ input: JSONValue, requestID: String, now: Date) throws -> JSONValue {
    try installAssistant()
    let stored = try db.record("wb_assistant_plans", id: requestID)
    if !stored.isEmpty {
      try require(stored.integer("cancelled") == 0 && stored[value: "result"].isNull
        && (try Clock.parse(stored.text("expires_at"))) > now, "这份预览已失效，请重新发送课表。")
      return try JSONDecoder().decode(
        AssistantPreparedPlan.self, from: Data(stored.text("payload").utf8)).timetablePreview()
    }

    func object(_ value: JSONValue, _ keys: Set<String>, _ message: String) throws -> Record {
      guard case .object(let fields) = value, Set(fields.keys).isSubset(of: keys) else {
        throw WorkBenchError(message)
      }
      return fields
    }
    func text(_ value: JSONValue, _ label: String, required: Bool = true) throws -> String {
      if !required && value.isNull { return "" }
      guard case .string(let raw) = value else { throw WorkBenchError("请提供" + label) }
      let val = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      try require((!required || !val.isEmpty) && val.count <= 100
        && !val.contains(where: \.isNewline), label + "缺失或格式不正确")
      return val
    }
    let term = try object(input["semester"], ["title", "first_monday", "weeks", "periods"], "请补充学期信息")
    let periods = term[value: "periods"].array
    try require((1...24).contains(periods.count), "请提供课表所用的节次开始和结束时间")
    for period in periods {
      _ = try object(period, ["number", "start", "end"], "节次格式不正确")
      _ = try Validation.integer(period["number"], 1...24)
      _ = try text(period["start"], "节次开始时间")
      _ = try text(period["end"], "节次结束时间")
    }
    let semesterFields: Record = [
      "title": .string(try text(term[value: "title"], "学期名称")),
      "first_monday": .string(try text(term[value: "first_monday"], "第一周周一的日期")),
      "weeks": try Validation.integer(term[value: "weeks"], 1...40),
      "periods": .array(periods.sorted { $0["number"].int < $1["number"].int }),
    ]
    let semesterID = UUID().uuidString.lowercased()
    func create(_ entity: WorkspaceEntity, _ id: String, _ fields: Record) -> AssistantPreparedChange {
      .init(id: id, kind: "create", entity: entity.rawValue, targetID: id,
        fields: fields, before: [:], versions: [:], associationNames: nil, attachImage: nil)
    }
    var changes = [create(.semesters, semesterID, semesterFields)]
    let courses = input["courses"].array
    try require((1...25).contains(courses.count), "请提供 1–25 门有明确上课安排的课程")
    var courseKeys = Set<[String]>()
    var occupied = Set<[Int64]>()
    for entry in courses {
      let course = try object(entry, ["title", "teacher", "code", "meetings"], "课程信息格式不正确")
      let id = UUID().uuidString.lowercased()
      let name = try text(course[value: "title"], "课程名称")
      let teacher = try text(course[value: "teacher"], "教师", required: false)
      let code = try text(course[value: "code"], "课程编号", required: false)
      try require(courseKeys.insert([name, code]).inserted, "课程重复，请把同一门课的上课安排合在一起")
      changes.append(create(.courses, id, ["semester_id": .string(semesterID), "title": .string(name),
        "teacher": .string(teacher), "code": .string(code), "status": .string("active")]))
      let meetings = course[value: "meetings"].array
      try require((1...14).contains(meetings.count), "请补充「\(name)」的星期、节次和教学周")
      for entry in meetings {
        let m = try object(entry, ["weekday", "period_start", "period_end", "weeks", "room"], "上课安排格式不正确")
        let weekday = try Validation.integer(m[value: "weekday"], 1...7).int
        let start = try Validation.integer(m[value: "period_start"], 1...24).int
        let end = try Validation.integer(m[value: "period_end"], start...24).int
        let weeks = try m[value: "weeks"].array.map { try Validation.integer($0, 1...semesterFields.integer("weeks")).int }.sorted()
        try require(!weeks.isEmpty && Set(weeks).count == weeks.count, "请补充「\(name)」的确切教学周")
        for week in weeks {
          for period in start...end {
            try require(occupied.insert([weekday, week, period]).inserted,
              "第 \(week) 周、星期 \(weekday) 的第 \(period) 节有重复或冲突，请先核对课表")
          }
        }
        changes.append(create(.courseMeetings, UUID().uuidString.lowercased(), [
          "course_id": .string(id), "weekday": .integer(weekday), "period_start": .integer(start),
          "period_end": .integer(end), "weeks": .array(weeks.map(JSONValue.integer)),
          "room": .string(try text(m[value: "room"], "教室", required: false)),
        ]))
      }
      try require(changes.count <= 81, "课表中的上课安排过多，请先精简")
    }

    // Exercise the same normal commands against the complete plan and roll back every change.
    do {
      try db.transaction {
        try requireNewSemester(semesterFields)
        for change in changes {
          guard let entity = WorkspaceEntity(rawValue: change.entity) else { throw WorkBenchError("课表类型不正确") }
          let fields = Dictionary(uniqueKeysWithValues: change.fields.compactMap { key, value in
            ItemField(rawValue: key).map { ($0, value) }
          })
          _ = try perform(.create(entity, id: change.targetID, fields: fields), now: now)
        }
        throw TimetableValidation.rollback
      }
    } catch TimetableValidation.rollback {}
    let plan = AssistantPreparedPlan(id: requestID, changes: changes,
      expiresAt: Clock.stamp(now.addingTimeInterval(1800)))
    let preview = try plan.timetablePreview()
    let payload = try JSONValue(data: JSONEncoder().encode(plan)).json()
    try db.execute("DELETE FROM wb_assistant_plans WHERE expires_at<=? AND result IS NULL", [.string(Clock.stamp(now))])
    try db.execute("INSERT INTO wb_assistant_plans(id,payload,created_at,expires_at) VALUES(?,?,?,?)",
      [.string(plan.id), .string(payload), .string(Clock.stamp(now)), .string(plan.expiresAt)])
    return preview
  }
}
