import Foundation
import Testing

@testable import WorkBenchKit

@Test func newTaskDefaultsAndAllPropertiesPersistTogether() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let now = try Clock.parse("2026-10-28T10:00:00+08:00")
  var entry = TaskEntryValues()
  entry.title = "仅填写名称"
  entry.schedule = TaskScheduleValues(now: now)
  let plain = try db.perform(.create(.tasks, fields: entry.fields(now: now)), now: now).id!
  #expect(try db.db.record("tasks", id: plain).integer("importance") == 1)
  #expect(try db.db.record("tasks", id: plain)[value: "reminder_enabled"] == .integer(0))
  #expect(try db.db.record("tasks", id: plain)[value: "start_time"].isNull)
  for entity in [WorkspaceEntity.projects, .learning, .courses] {
    let id: String
    if entity == .courses {
      _ = try db.perform(.installTimetable, now: now)
      id = try db.snapshot()[.courses][0].id
    } else {
      id = try db.perform(.create(entity, fields: [.title: .string("关联集合")]), now: now).id!
    }
    entry.association = try db.snapshot().item(entity, id)
    entry.title = "带属性的任务"
    entry.notes = "多行备注\n保留文字"
    entry.importance = 5
    entry.schedule.timed = true
    entry.schedule.reminder = true
    entry.schedule.start = now.addingTimeInterval(3600)
    entry.schedule.end = now.addingTimeInterval(7200)
    let task = try db.perform(.create(.tasks, fields: entry.fields(now: now)), now: now).id!
    let snapshot = try db.snapshot()
    let item = snapshot.item(.tasks, task)!
    #expect(snapshot.association(item)?.id == id)
    #expect(item.importance == 5 && item[.notes].string == entry.notes)
    #expect(item[.startTime].string == "11:00" && item[.endTime].string == "12:00")
    #expect(item[.reminderEnabled] == .integer(1))
    #expect(
      taskReminderRows(snapshot: snapshot, now: now).contains { $0.id == "workbench-task:" + task })
  }
}

@Test func newTaskInvalidPropertiesCannotLeavePartialRows() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let now = try Clock.parse("2026-10-28T10:00:00+08:00")
  var entry = TaskEntryValues()
  entry.schedule = TaskScheduleValues(now: now)
  #expect(throws: (any Error).self) { try entry.fields(now: now) }
  entry.title = "新任务"
  entry.importance = 6
  #expect(throws: (any Error).self) { try entry.fields(now: now) }
  entry.importance = 1
  entry.schedule.timed = true
  entry.schedule.start = now
  entry.schedule.end = now.addingTimeInterval(-3600)
  #expect(throws: (any Error).self) { try entry.fields(now: now) }
  entry.schedule.end = now.addingTimeInterval(3600)
  entry.schedule.reminder = true
  #expect(throws: (any Error).self) { try entry.fields(now: now) }
  entry.schedule.reminder = false
  entry.association = WorkspaceItem(entity: .projects, fields: ["id": .string("missing-project")])
  #expect(throws: (any Error).self) {
    try db.perform(.create(.tasks, fields: entry.fields(now: now)), now: now)
  }
  #expect(try db.snapshot()[.tasks].isEmpty)
}

@Test func sharedScheduleRestoresTimeAndDisablesReminderWithoutTime() throws {
  let now = try Clock.parse("2026-10-28T10:00:00+08:00")
  let item = WorkspaceItem(
    entity: .tasks,
    fields: [
      "id": .string("scheduled"), "planned_date": .string("2026-10-29"),
      "start_time": .string("13:10"), "end_time": .string("14:20"), "reminder_enabled": .integer(1),
    ])
  var value = TaskScheduleValues(item: item, now: now)
  #expect(Clock.day(value.date) == "2026-10-29" && value.timed && value.needsReminderPermission)
  #expect(try value.fields(now: now)[.startTime] == .string("13:10"))
  #expect(try value.fields(now: now)[.endTime] == .string("14:20"))
  value.timed = false
  #expect(!value.needsReminderPermission)
  #expect(try value.fields(now: now)[.reminderEnabled] == .integer(0))
  #expect(try value.fields(now: now)[.startTime] == .null)
  let fields = try itemAssociationFields(nil)
  #expect(fields[.projectID] == .null && fields[.learningID] == .null && fields[.courseID] == .null)
}

@Test func taskImportanceOrderAndAssociationStayConsistentAfterEveryLevel() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let project = try db.perform(.create(.projects, fields: [.title: .string("共同项目")]), now: testNow)
    .id!
  for id in ["b", "a", "c"] {
    _ = try db.perform(
      .create(.tasks, id: id, fields: [.title: .string(id), .projectID: .string(project)]),
      now: testNow)
  }
  #expect(try db.snapshot()[.tasks].sorted(by: taskImportanceOrder).map(\.id) == ["a", "b", "c"])
  for level in [5, 4, 3, 2, 1] {
    _ = try db.perform(
      .update(.tasks, id: "c", fields: [.importance: .integer(Int64(level))]),
      now: testNow.addingTimeInterval(Double(6 - level)))
    let snapshot = try db.snapshot()
    let ordered = snapshot[.tasks].sorted(by: taskImportanceOrder)
    #expect(ordered.map(\.id) == (level > 1 ? ["c", "a", "b"] : ["a", "b", "c"]))
    let item = try #require(snapshot.item(.tasks, "c"))
    #expect(item.importance == level && snapshot.association(item)?.id == project)
    #expect(
      snapshot[.tasks].filter { $0[.projectID].string == project }.sorted(by: taskImportanceOrder)
        .map(\.id) == ordered.map(\.id))
  }
  #expect(try db.snapshot()[.tasks].count == 3)
}
