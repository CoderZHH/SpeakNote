import Foundation

/// Shared by new-task composition and the existing calendar/task time editor.
struct TaskScheduleValues: Equatable, Sendable {
  var hasPlannedDate: Bool
  var date: Date
  var hasDueDate: Bool
  var dueDate: Date
  var start: Date
  var end: Date
  var timed: Bool
  var reminder: Bool
  var reminderAt: Date?

  init(now: Date = .now) {
    hasPlannedDate = true
    date = now
    hasDueDate = false
    dueDate = now
    // Start on a future minute, so enabling a reminder needs no correction first.
    let next = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60)
    start = next
    end = next.addingTimeInterval(3600)
    timed = false
    reminder = false
  }
  init(item: WorkspaceItem, now: Date = .now) {
    self.init(now: now)
    let day = item[.plannedDate].string
    hasPlannedDate = !item[.plannedDate].isNull && !day.isEmpty
    if let value = try? Clock.parse(day + "T00:00:00+08:00") { date = value }
    let due = item[.dueDate].string
    if !item[.dueDate].isNull, !due.isEmpty,
      let value = try? Clock.parse(due + "T00:00:00+08:00")
    {
      dueDate = value
      hasDueDate = true
    }
    if hasPlannedDate, let value = try? Clock.parse(day + "T" + item[.startTime].string + ":00+08:00") {
      start = value
      timed = true
    }
    if hasPlannedDate, let value = try? Clock.parse(day + "T" + item[.endTime].string + ":00+08:00") {
      end = value
    }
    reminderAt = try? Clock.parse(item[.reminderAt].string)
    reminder = ((hasPlannedDate && timed) || reminderAt != nil) && item[.reminderEnabled].bool
  }
  var needsReminderPermission: Bool { ((hasPlannedDate && timed) || reminderAt != nil) && reminder }
  static func time(_ date: Date) -> String {
    let parts = Clock.calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour!, parts.minute!)
  }
  func fields(now: Date = .now) throws -> [ItemField: JSONValue] {
    let activeTimed = hasPlannedDate && timed
    let from = Self.time(start)
    let until = Self.time(end)
    if activeTimed { try require(from < until, "结束时间需晚于开始时间。") }
    if needsReminderPermission {
      let at = try reminderAt ?? Clock.parse(Clock.day(date) + "T" + from + ":00+08:00")
      try require(at > now, "提醒时间已过，请调整或关闭提醒。")
    }
    var output: [ItemField: JSONValue] = [
      .plannedDate: hasPlannedDate ? .string(Clock.day(date)) : .null,
      .startTime: activeTimed ? .string(from) : .null,
      .endTime: activeTimed ? .string(until) : .null,
      .reminderEnabled: .integer(needsReminderPermission ? 1 : 0),
      .reminderAt: needsReminderPermission ? reminderAt.map { .string(Clock.stamp($0)) } ?? .null : .null,
    ]
    output[.dueDate] = hasDueDate ? .string(Clock.day(dueDate)) : .null
    return output
  }
  var summary: String {
    let planPart: String
    if hasPlannedDate {
      let day = Clock.day(date)
      let label = day == Clock.day() ? "今日" : day.replacingOccurrences(of: "-", with: "/")
      planPart = label + (timed ? " · " + Self.time(start) + "–" + Self.time(end) : "")
    } else {
      planPart = "以后"
    }
    if hasDueDate {
      let due = String(Clock.day(dueDate).suffix(5)).replacingOccurrences(of: "-", with: "/")
      return planPart + " · \(due) 截止"
    }
    return planPart
  }
}

func itemAssociationFields(_ item: WorkspaceItem?) throws -> [ItemField: JSONValue] {
  var result: [ItemField: JSONValue] = [
    .projectID: .null, .learningID: .null, .courseID: .null, .collectionID: .null,
  ]
  guard let item else { return result }
  let field: ItemField
  switch item.entity {
  case .collections: field = .collectionID
  case .projects: field = .projectID
  case .learning: field = .learningID
  case .courses: field = .courseID
  default: throw WorkBenchError("请选择空间卡片、项目、学习或课程")
  }
  result[field] = .string(item.id)
  return result
}

struct TaskEntryValues {
  var title = ""
  var notes = ""
  var importance = 1
  var association: WorkspaceItem?
  var schedule = TaskScheduleValues()

  func fields(now: Date = .now) throws -> [ItemField: JSONValue] {
    _ = try Validation.text(.string(title), "任务名称", max: 500, required: true)
    _ = try Validation.integer(.integer(Int64(importance)), 1...5)
    var result = try schedule.fields(now: now)
    result.merge(try itemAssociationFields(association)) { _, value in value }
    result[.title] = .string(title)
    result[.notes] = .string(notes)
    result[.importance] = .integer(Int64(importance))
    return result
  }
}

/// Every checklist projects the same task priority, with stable ties after edits.
func taskImportanceOrder(_ lhs: WorkspaceItem, _ rhs: WorkspaceItem) -> Bool {
  lhs.importance == rhs.importance
    ? (lhs.createdAt, lhs.id) < (rhs.createdAt, rhs.id)
    : lhs.importance > rhs.importance
}

func isTaskDueForToday(_ task: WorkspaceItem, day: String) -> Bool {
  task.status == "todo" && !task[.plannedDate].isNull && task[.plannedDate].string <= day
}

/// Completion belongs to the day it happened, independently of the original plan.
func tasksCompleted(on day: Date, in tasks: [WorkspaceItem]) -> [WorkspaceItem] {
  let interval = Clock.calendar.dateInterval(of: .day, for: day)!
  return tasks.compactMap { item -> (WorkspaceItem, Date)? in
    guard item.status == "done",
      let completed = try? Clock.parse(item.fields.text("completed_at")),
      completed >= interval.start, completed < interval.end
    else { return nil }
    return (item, completed)
  }.sorted {
    $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1
  }.map(\.0)
}
