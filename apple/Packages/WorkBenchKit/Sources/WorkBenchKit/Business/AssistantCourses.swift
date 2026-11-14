import Foundation

extension WorkspaceEngine {
  func assistantCourseSchedule(_ arguments: JSONValue) throws -> JSONValue {
    let day = try assistantCourseDay(arguments["date"])
    let rows = courseOccurrences(snapshot: try snapshot(), day: day, allWeek: arguments["week"].bool)
    return .object(["items": .array(try rows.map { try .object(assistantCourseFields($0)) })])
  }

  private func assistantCourseDay(_ value: JSONValue) throws -> Date {
    let date = try Validation.day(value)
    try require(!date.isNull, "请提供查询的日期")
    return try Clock.parse(date.string + "T00:00:00+08:00")
  }

  private func assistantCourseFields(_ row: CourseOccurrence) throws -> Record {
    let values: Record = [
      "occurrence_id": .string(row.id), "course_id": .string(row.course.id),
      "title": .string(row.course.title), "date": .string(Clock.day(row.day)),
      "start_time": .string(row.start), "end_time": .string(row.end),
      "room": row.meeting[.room],
    ]
    return values.merging(["version": .string(try assistantVersion(values))]) { _, new in new }
  }

  func assistantCourseReminder(_ request: JSONValue, now: Date) throws -> JSONValue {
    try require(request["entity"] == .string("courses"), "请指定要提醒的课程")
    let occurrenceID = request["occurrence_id"].string
    let day = try assistantCourseDay(.string(String(occurrenceID.suffix(10))))
    let rows = courseOccurrences(snapshot: try snapshot(), day: day)
    guard let row = rows.first(where: { $0.id == occurrenceID }) else {
      throw WorkBenchError("这次上课安排已变化，请重新查询")
    }
    let current = try assistantCourseFields(row)
    try require(current["version"] == request["expected_version"], "上课安排已变化，请重新查询")
    let lead = request["minutes_before"].isNull ? 10 : try Validation.integer(request["minutes_before"], 0...1440).int
    let starts = try Clock.parse(Clock.day(row.day) + "T" + row.start + ":00+08:00")
    let reminder = starts.addingTimeInterval(-60 * Double(lead))
    try require(reminder > now, "提醒时间已过，请选择未来的一次课程")
    return .object(["kind": .string("create"), "entity": .string("tasks"), "fields": .object([
      "title": .string("上课：" + row.course.title), "course_id": .string(row.course.id),
      "notes": .string("\(Clock.day(row.day)) \(row.start) 上课，\(row.meeting[.room].string)"),
      "planned_date": .string(Clock.day(reminder)), "reminder_at": .string(Clock.stamp(reminder)), "reminder_enabled": .bool(true),
    ])])
  }
}
