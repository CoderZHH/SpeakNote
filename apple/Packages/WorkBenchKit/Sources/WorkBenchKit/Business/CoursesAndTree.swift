import Foundation

extension WorkspaceEngine {
  func validateCourse(_ entity: WorkspaceEntity, _ row: inout Record) throws {
    func list(_ value: JSONValue) throws -> [JSONValue] {
      let v = try value.isString ? JSONValue(json: value.string) : value
      guard case .array(let result) = v else { throw WorkBenchError("课表格式不正确") }
      return result
    }
    switch entity {
    case .semesters:
      let day = try Validation.day(row[value: "first_monday"])
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd"
      f.calendar = Clock.calendar
      f.timeZone = Clock.calendar.timeZone
      try require(
        f.date(from: day.string).map { Clock.calendar.component(.weekday, from: $0) == 2 } == true,
        "第一教学周需从周一开始")
      _ = try Validation.integer(row[value: "weeks"], 1...40)
      let periods = try list(row[value: "periods"])
      try require((1...24).contains(periods.count), "请设置 1–24 节作息")
      var previous = -1
      var seen = Set<Int64>()
      for p in periods {
        _ = try Validation.integer(p["number"], 1...24)
        try require(seen.insert(p["number"].int).inserted, "节次重复")
        guard let start = timeMinutes(p["start"].string), let end = timeMinutes(p["end"].string)
        else { throw WorkBenchError("作息时间不正确") }
        try require(start >= previous && end > start, "作息时间不能重叠")
        previous = end
      }
      row["periods"] = .string(try JSONValue.array(periods).json())
    case .courses:
      _ = try exists(.semesters, row.text("semester_id"))
      if row["color"] == nil { row["color"] = .string("#648ba8") }
      try require(
        row.text("color").range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
        "课程颜色不正确")
    case .courseMeetings:
      let course = try exists(.courses, row.text("course_id"))
      let term = try exists(.semesters, course.text("semester_id"))
      _ = try Validation.integer(row[value: "weekday"], 1...7)
      let weeks = try list(row[value: "weeks"])
      try require(!weeks.isEmpty && Set(weeks).count == weeks.count, "教学周不能为空或重复")
      for week in weeks { _ = try Validation.integer(week, 1...term.integer("weeks")) }
      let start = try Validation.integer(row[value: "period_start"], 1...24).int
      let end = try Validation.integer(row[value: "period_end"], start...24).int
      let periods = try list(term[value: "periods"]).map { $0["number"].int }
      try require((start...end).allSatisfy(periods.contains), "节次不在学期作息中")
      row["weeks"] = .string(try JSONValue.array(weeks).json())
    default: break
    }
  }
  func installTimetable() throws {
    let key = "timetable.initial.2026-autumn"
    if try db.one("SELECT value FROM settings WHERE key=?", [.string(key)]).isEmpty {
      let document = try JSONValue(
        data: Data(
          contentsOf: Bundle.module.url(forResource: "default-timetable", withExtension: "json")!))
      var term = document["semester"].object
      if try db.record("semesters", id: term.identifier).isEmpty {
        term["created_at"] = .string("2026-10-13T15:26:10.000Z")
        try validateCourse(.semesters, &term)
        try db.insert("semesters", term)
        for value in document["courses"].array {
          var course = value.object
          let meetings = course.removeValue(forKey: "meetings")?.array ?? []
          course["semester_id"] = term[value: "id"]
          course["created_at"] = term[value: "created_at"]
          course["status"] = .string("active")
          try validateCourse(.courses, &course)
          try db.insert("courses", course)
          for value in meetings {
            var meeting = value.object
            meeting["course_id"] = course[value: "id"]
            meeting["created_at"] = term[value: "created_at"]
            try validateCourse(.courseMeetings, &meeting)
            try db.insert("course_meetings", meeting)
          }
        }
      }
      try db.execute("INSERT OR IGNORE INTO settings VALUES(?, '1')", [.string(key)])
    }
    let first = try db.record("course_meetings", id: "meeting-2026-management-frontiers-1")
    let second = try db.record("course_meetings", id: "meeting-2026-management-frontiers-2")
    if !first.isEmpty && !second.isEmpty
      && first.text("course_id") == "course-2026-management-frontiers"
      && first["course_id"] == second["course_id"] && first.integer("period_start") == 1
      && first.integer("period_end") == 2 && second.integer("period_start") == 3
      && second.integer("period_end") == 4
      && ["weekday", "weeks", "room"].allSatisfy({ first[$0] == second[$0] })
    {
      try db.update("course_meetings", id: first.identifier, ["period_end": .integer(4)])
      try db.execute("DELETE FROM course_meetings WHERE id=?", [second[value: "id"]])
    }
  }
  func move(
    _ entity: WorkspaceEntity, id: String, targetEntity: WorkspaceEntity, targetID: String,
    placement: MovePlacement, now: Date
  ) throws {
    try require(
      [.learning, .lessons].contains(entity) && [.learning, .lessons].contains(targetEntity)
        && (entity == .lessons || targetEntity == .learning)
        && !(entity == .lessons && targetEntity == .learning && placement != .inside), "移动目标不正确")
    let moving = try exists(entity, id)
    let target = try exists(targetEntity, targetID)
    let rows = try db.rows("SELECT * FROM \(quote(entity.rawValue)) ORDER BY position,id")
    let parent: JSONValue =
      entity == .lessons && targetEntity == .learning
      ? .null : placement == .inside ? .string(targetID) : target[value: "parent_id"]
    let learning =
      targetEntity == .learning ? JSONValue.string(targetID) : target[value: "learning_id"]
    var subtree: Set<String> = [id]
    while true {
      let previous = subtree
      for row in rows where subtree.contains(row.text("parent_id")) {
        subtree.insert(row.identifier)
      }
      if previous == subtree { break }
    }
    try require(
      !(entity == targetEntity && subtree.contains(targetID)) && !subtree.contains(parent.string),
      "不能移到自己或下级中")
    var siblings = rows.filter {
      $0.identifier != id && $0[value: "parent_id"] == parent
        && (entity != .lessons || $0[value: "learning_id"] == learning)
    }
    let index: Int
    if placement == .inside {
      index = siblings.count
    } else {
      guard let found = siblings.firstIndex(where: { $0.identifier == targetID }) else {
        throw WorkBenchError("插入位置已变化")
      }
      index = found + (placement == .after ? 1 : 0)
    }
    try db.update(entity.rawValue, id: id, ["parent_id": parent])
    if entity == .lessons {
      for row in rows where subtree.contains(row.identifier) {
        try db.update("lessons", id: row.identifier, ["learning_id": learning])
        if !row[value: "task_id"].isNull {
          try db.execute(
            "UPDATE tasks SET learning_id=?,updated_at=? WHERE id=? AND learning_id=?",
            [
              learning, .string(Clock.stamp(now)), row[value: "task_id"],
              moving[value: "learning_id"],
            ])
        }
      }
    }
    siblings.insert(moving, at: index)
    for (index, row) in siblings.enumerated() {
      try db.update(entity.rawValue, id: row.identifier, ["position": .integer(Int64(index))])
    }
    if moving[value: "parent_id"] != parent
      || (entity == .lessons && moving[value: "learning_id"] != learning)
    {
      let old = rows.filter {
        $0.identifier != id && $0[value: "parent_id"] == moving[value: "parent_id"]
          && (entity != .lessons || $0[value: "learning_id"] == moving[value: "learning_id"])
      }
      for (index, row) in old.enumerated() {
        try db.update(entity.rawValue, id: row.identifier, ["position": .integer(Int64(index))])
      }
    }
  }
}
