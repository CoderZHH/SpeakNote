import Foundation
import Testing

@testable import WorkBenchKit

private func newAssistantTask(_ title: String = "实验报告") -> JSONValue {
  .object([
    "kind": .string("create"), "entity": .string("tasks"),
    "fields": .object(["title": .string(title), "planned_date": .string("2026-11-13")]),
  ])
}

@Test func assistantTodayTasksFollowPlanAndActualCompletionInsteadOfCreation() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let now = try Clock.parse("2026-11-11T01:00:00+08:00")
  let yesterday = now.addingTimeInterval(-86400)
  for (id, planned, status, created) in [
    ("due-today", JSONValue.string("2026-11-11"), "todo", yesterday),
    ("overdue", .string("2026-11-10"), "todo", yesterday),
    ("future", .string("2026-11-12"), "todo", now),
    ("unscheduled", .null, "todo", now),
    ("done-today", .string("2026-11-10"), "done", now),
    ("done-yesterday", .string("2026-11-11"), "done", yesterday),
    ("abandoned", .string("2026-11-11"), "abandoned", now),
  ] {
    try engine.perform(.create(.tasks, id: id, fields: [
      .title: .string(id), .plannedDate: planned, .status: .string(status),
    ]), now: created)
  }
  let result = try engine.assistantSearch(.object(["entity": .string("tasks"), "task_view": .string("today")]), now: now)
  #expect(result["date"] == .string("2026-11-11"))
  #expect(result["total"] == .integer(2))
  #expect(result["items"].array.map { $0["fields"]["id"].string } == ["due-today", "overdue"])
  #expect(result["completed_total"] == .integer(1))
  #expect(result["completed_today"].array.map { $0["fields"]["id"].string } == ["done-today"])
}

@Test func assistantPreparationIsReadOnlyAndReplayIsPersistent() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let plan = try engine.prepareAssistantPlan(
    .array([newAssistantTask()]), source: "添加报告", now: testNow)
  #expect(try engine.snapshot()[.tasks].isEmpty)
  let first = try engine.commitAssistantPlan(id: plan.id, now: testNow)
  let reopened = try fixture.workspace()
  let replay = try reopened.commitAssistantPlan(id: plan.id, now: testNow.addingTimeInterval(10000))
  #expect(first == replay)
  #expect(try reopened.snapshot()[.tasks].map(\.id) == [plan.changes[0].targetID])
  #expect(try reopened.db.record("wb_assistant_plans", id: plan.id).text("payload") == "{}")
}

@Test func assistantDetectsNoteChangesWithoutUpdatedAtAndRollsBackEntirePlan() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let noteID = try engine.perform(.create(.notes, fields: [.content: .string("原笔记")]), now: testNow)
    .id!
  let before = try engine.db.record("notes", id: noteID)
  let update: JSONValue = .object([
    "kind": .string("update"), "entity": .string("notes"),
    "target_id": .string(noteID), "expected_version": .string(try engine.assistantVersion(before)),
    "fields": .object(["content": .string("模型整理")]),
  ])
  let plan = try engine.prepareAssistantPlan(
    .array([newAssistantTask(), update]), source: "整理", now: testNow)
  _ = try engine.perform(
    .update(.notes, id: noteID, fields: [.content: .string("手机刚改的")]), now: testNow)
  #expect(throws: (any Error).self) { try engine.commitAssistantPlan(id: plan.id, now: testNow) }
  #expect(try engine.snapshot()[.tasks].isEmpty)
  #expect(try engine.db.record("notes", id: noteID).text("content") == "手机刚改的")
}

@Test func assistantRejectsExpiredPlansUnsupportedEntitiesAndProtectedFields() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let plan = try engine.prepareAssistantPlan(
    .array([newAssistantTask()]), source: "新增", now: testNow)
  #expect(throws: (any Error).self) {
    try engine.commitAssistantPlan(id: plan.id, now: testNow.addingTimeInterval(601))
  }
  for request: JSONValue in [
    .object([
      "kind": .string("create"), "entity": .string("accounts"),
      "fields": .object(["name": .string("账号")]),
    ]),
    .object(["kind": .string("delete"), "entity": .string("tasks"), "fields": .object([:])]),
    .object([
      "kind": .string("create"), "entity": .string("tasks"),
      "fields": .object(["title": .string("任务"), "reminder_enabled": .integer(1)]),
    ]),
  ] {
    #expect(throws: (any Error).self) {
      try engine.prepareAssistantPlan(.array([request]), source: "", now: testNow)
    }
  }
  #expect(throws: (any Error).self) {
    try engine.assistantSearch(.object(["entity": .string("accounts")]))
  }
  #expect(try engine.snapshot()[.tasks].isEmpty)
}

@Test func assistantCourseTaskKeepsIdentityAndNoticesAssociationChanges() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  _ = try engine.perform(.installTimetable, now: testNow)
  let course = try engine.snapshot()[.courses][0]
  var request = newAssistantTask()
  request["fields"]["course_id"] = .string(course.id)
  let plan = try engine.prepareAssistantPlan(.array([request]), source: "关联资料", now: testNow)
  _ = try engine.perform(
    .update(.courses, id: course.id, fields: [.title: .string("已改名")]), now: testNow)
  #expect(throws: (any Error).self) { try engine.commitAssistantPlan(id: plan.id, now: testNow) }
  let refreshed = try engine.prepareAssistantPlan(.array([request]), source: "关联资料", now: testNow)
  _ = try engine.commitAssistantPlan(id: refreshed.id, now: testNow)
  let task = try engine.snapshot()[.tasks][0]
  #expect(task.id == refreshed.changes[0].targetID && task[.courseID] == .string(course.id))
  #expect(try engine.pendingDocuments().contains { $0.id == task.id && $0.entity == "tasks" })
}

@Test func assistantMemoryForgetRemovesContentAndCompletedProposalPayload() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let request: JSONValue = .object([
    "kind": .string("remember"), "entity": .string("memory"),
    "fields": .object(["content": .string("喜欢简短回复")]),
  ])
  let plan = try engine.prepareAssistantPlan(.array([request]), source: "以后说重点", now: testNow)
  _ = try engine.commitAssistantPlan(id: plan.id, now: testNow)
  let row = try engine.assistantRecord(entity: "memory", id: plan.changes[0].targetID)
  let forget: JSONValue = .object([
    "kind": .string("forget"), "entity": .string("memory"),
    "target_id": row[value: "id"], "expected_version": .string(try engine.assistantVersion(row)),
    "fields": .object([:]),
  ])
  let removal = try engine.prepareAssistantPlan(.array([forget]), source: "忘记这个偏好", now: testNow)
  _ = try engine.commitAssistantPlan(id: removal.id, now: testNow)
  #expect(try engine.assistantSearch(.object(["entity": .string("memory")]))["items"].array.isEmpty)
  #expect(
    try engine.db.rows("SELECT payload FROM wb_assistant_plans").allSatisfy {
      $0.text("payload") == "{}"
    })
  #expect(try engine.pendingDocuments().allSatisfy { $0.entity != "memory" })
}

@Test func assistantAttachmentFailureRollsBackBusinessAndCopiedFiles() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let database = try WorkspaceDatabase(
    url: fixture.directory.appendingPathComponent("workbench.sqlite"))
  let staging = EntryAttachmentStaging()
  // Tiny valid PNG; exercise actual file staging and rollback, not the model.
  let png = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
  )!
  let valid = try await staging.add(data: png, name: "作业.png")
  let missing = try await staging.add(data: png, name: "缺失.png")
  try await staging.remove(missing)
  let plan = try await database.prepareAssistantPlan(
    .array([newAssistantTask()]), source: "图片作业", now: testNow)
  await #expect(throws: (any Error).self) {
    try await database.commitAssistantPlan(
      id: plan.id, attachments: [valid, missing], now: testNow)
  }
  #expect(try await database.snapshot()[.tasks].isEmpty)
  let folder = fixture.directory.appendingPathComponent("attachments")
  #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  _ = try await database.commitAssistantPlan(id: plan.id, attachments: [valid], now: testNow)
  let snapshot = try await database.snapshot()
  #expect(snapshot[.tasks].count == 1 && snapshot[.attachments].count == 1)
  _ = try await database.commitAssistantPlan(id: plan.id, attachments: [valid], now: testNow)
  #expect(try await database.snapshot()[.attachments].count == 1)
  await staging.discard()
}

@Test func assistantReminderAndCompletionUseNativeScheduleAndHistory() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let now = try Clock.parse("2026-11-10T09:00:00+08:00")
  let apply: JSONValue = .array([
    .object([
      "kind": .string("create"), "entity": .string("tasks"),
      "fields": .object(["title": .string("寄快递"), "planned_date": .string("2026-11-12"),
        "reminder_at": .string("2026-11-11T18:30:00+08:00")]),
    ]),
    .object([
      "kind": .string("create"), "entity": .string("tasks"),
      "fields": .object(["title": .string("写完报告"), "status": .string("done")]),
    ]),
  ])
  _ = try engine.applyAssistantChanges(apply, requestID: "direct-reminder", attachments: [], now: now)
  let snapshot = try engine.snapshot()
  let task = try #require(snapshot[.tasks].first { $0.title == "寄快递" })
  #expect(task[.plannedDate] == .string("2026-11-12"))
  #expect(task[.startTime].isNull)
  let notification = try #require(taskReminderRows(snapshot: snapshot, now: now).first)
  #expect(notification.date == (try Clock.parse("2026-11-11T18:30:00+08:00")))
  #expect(tasksCompleted(on: now, in: snapshot[.tasks]).map(\.title) == ["写完报告"])

  let changed = try TaskScheduleValues(item: task, now: now).fields(now: now)
  #expect(changed[.reminderAt] == task[.reminderAt])
}

@Test func assistantCourseReminderUsesOccurrenceAndRejectsStaleSchedule() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let now = try Clock.parse("2026-11-10T09:00:00+08:00")
  let term = try #require(engine.perform(.create(.semesters, fields: [
    .title: .string("测试学期"), .firstMonday: .string("2026-11-09"), .weeks: .integer(10),
    .periods: .array([.object(["number": .integer(1), "start": .string("09:00"), "end": .string("09:45")])]),
  ]), now: now).id)
  let course = try #require(engine.perform(.create(.courses, fields: [
    .title: .string("测试课程"), .semesterID: .string(term),
  ]), now: now).id)
  let meeting = try #require(engine.perform(.create(.courseMeetings, fields: [
    .courseID: .string(course), .weekday: .integer(3), .weeks: .array([.integer(1)]),
    .periodStart: .integer(1), .periodEnd: .integer(1), .room: .string("A101"),
  ]), now: now).id)
  let arguments: JSONValue = .object(["date": .string("2026-11-11")])
  var occurrence = try #require(engine.assistantCourseSchedule(arguments)["items"].array.first)
  #expect(occurrence["title"] == .string("测试课程") && occurrence["room"] == .string("A101"))
  func changes() -> JSONValue {
    .array([.object([
      "kind": .string("remind_course"), "entity": .string("courses"),
      "occurrence_id": occurrence["occurrence_id"], "expected_version": occurrence["version"],
      "minutes_before": .integer(15),
    ])])
  }
  _ = try engine.perform(.update(.courseMeetings, id: meeting, fields: [.room: .string("A102")]), now: now)
  #expect(throws: WorkBenchError.self) {
    try engine.applyAssistantChanges(changes(), requestID: "stale-course", attachments: [], now: now)
  }
  #expect(try engine.snapshot()[.tasks].isEmpty)
  occurrence = try #require(engine.assistantCourseSchedule(arguments)["items"].array.first)
  _ = try engine.applyAssistantChanges(changes(), requestID: "current-course", attachments: [], now: now)
  let snapshot = try engine.snapshot()
  #expect(snapshot[.tasks].first?[.courseID] == .string(course))
  #expect(taskReminderRows(snapshot: snapshot, now: now).first?.date ==
    (try Clock.parse("2026-11-11T08:45:00+08:00")))
}

@Test func assistantBatchFailureKeepsLearningAndAttachmentsAtomic() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let before = try engine.snapshot()
  let changes: JSONValue = .array([
    .object(["kind": .string("create"), "entity": .string("learning"), "ref": .string("topic"),
      "fields": .object(["title": .string("Deep Agents")])]),
    .object(["kind": .string("create"), "entity": .string("tasks"),
      "fields": .object(["title": .string("完成第一课"), "learning_id": .string("@topic")])]),
    .object(["kind": .string("update"), "entity": .string("tasks"), "target_id": .string("missing"),
      "expected_version": .string("unknown"), "fields": .object(["status": .string("done")])]),
  ])
  #expect(throws: WorkBenchError.self) {
    try engine.applyAssistantChanges(changes, requestID: "failed-batch", attachments: [], now: testNow)
  }
  #expect(try engine.snapshot()[.learning] == before[.learning])
  #expect(try engine.snapshot()[.tasks] == before[.tasks])

  let note = try #require(engine.perform(.create(.notes, fields: [.content: .string("想法")]), now: testNow).id)
  let row = try engine.assistantRecord(entity: "notes", id: note)
  let staging = EntryAttachmentStaging()
  let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
  let attachment = try await staging.add(data: bytes, name: "附图.png")
  let imageChange: JSONValue = .array([.object([
    "kind": .string("update"), "entity": .string("notes"), "target_id": .string(note),
    "expected_version": .string(try engine.assistantVersion(row)), "attach_image": .bool(true),
  ])])
  _ = try engine.applyAssistantChanges(imageChange, requestID: "attach-existing", attachments: [attachment], now: testNow)
  #expect(try engine.db.rows("SELECT * FROM attachments").first?["note_id"] == .string(note))
  #expect(try engine.db.record("notes", id: note).text("content") == "想法")
  await staging.discard()
}

@Test func assistantTaskDeletionChecksVersionCascadesAndReplaysReceipt() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let chosen = try #require(engine.perform(.create(.tasks, fields: [.title: .string("同名任务")]), now: testNow).id)
  let other = try #require(engine.perform(.create(.tasks, fields: [.title: .string("同名任务")]), now: testNow).id)
  let note = try #require(engine.perform(.create(.notes, fields: [.content: .string("保留想法")]), now: testNow).id)
  _ = try engine.perform(.startFocus(taskID: chosen), now: testNow)
  let before = try engine.assistantVersion(engine.assistantRecord(entity: "tasks", id: chosen))
  func removal(version: String, entity: String = "tasks", id: String? = nil) -> JSONValue {
    .array([.object([
      "kind": .string("delete"), "entity": .string(entity),
      "target_id": .string(id ?? chosen), "expected_version": .string(version),
    ])])
  }
  #expect(throws: WorkBenchError.self) {
    try engine.applyAssistantChanges(removal(version: before, entity: "notes", id: note),
      requestID: "wrong-entity", attachments: [], now: testNow)
  }
  _ = try engine.perform(.update(.tasks, id: chosen, fields: [.title: .string("已改名")]), now: testNow)
  #expect(throws: WorkBenchError.self) {
    try engine.applyAssistantChanges(removal(version: before), requestID: "stale-delete",
      attachments: [], now: testNow)
  }
  #expect(try engine.snapshot()[.tasks].count == 2)
  let current = try engine.assistantVersion(engine.assistantRecord(entity: "tasks", id: chosen))
  let result = try engine.applyAssistantChanges(removal(version: current), requestID: "delete-once",
    attachments: [], now: testNow)
  let repeated = try engine.applyAssistantChanges(removal(version: current), requestID: "delete-once",
    attachments: [], now: testNow)
  #expect(result == repeated)
  let data = try engine.snapshot()
  #expect(data[.tasks].map(\.id) == [other])
  #expect(data[.notes].map(\.id) == [note])
  #expect(data[.focusSessions].isEmpty && data[.focusIntervals].isEmpty)
  #expect(try engine.pendingDocuments().contains { $0.entity == "tasks" && $0.id == chosen && $0.payload.isNull })
}
