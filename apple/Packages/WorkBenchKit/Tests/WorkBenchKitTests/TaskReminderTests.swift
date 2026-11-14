import Foundation
import Testing

@testable import WorkBenchKit

private let reminderNow = try! Clock.parse("2026-10-28T09:00:00+08:00")

@Test func taskReminderTracksScheduleAndLifecycle() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let id = try db.perform(
    .create(
      .tasks,
      fields: [
        .title: .string("拍照"),
        .plannedDate: .string("2026-10-28"), .startTime: .string("10:00"),
        .endTime: .string("11:00"),
        .reminderEnabled: .integer(1),
      ]), now: reminderNow
  ).id!
  let firstDate = try Clock.parse("2026-10-28T10:00:00+08:00")
  let movedDate = try Clock.parse("2026-10-28T10:30:00+08:00")
  var rows = taskReminderRows(snapshot: try db.snapshot(), now: reminderNow)
  #expect(rows.count == 1 && rows[0].id == "workbench-task:" + id)
  #expect(rows[0].date == firstDate)
  _ = try db.perform(
    .update(.tasks, id: id, fields: [.startTime: .string("10:30")]), now: reminderNow)
  rows = taskReminderRows(snapshot: try db.snapshot(), now: reminderNow)
  #expect(rows.count == 1 && rows[0].date == movedDate)
  for status in ["done", "abandoned", "todo"] {
    _ = try db.perform(
      .update(.tasks, id: id, fields: [.status: .string(status)]), now: reminderNow)
    #expect(
      taskReminderRows(snapshot: try db.snapshot(), now: reminderNow).count
        == (status == "todo" ? 1 : 0))
  }
  #expect(
    taskReminderRows(snapshot: try db.snapshot(), now: reminderNow.addingTimeInterval(7200)).isEmpty
  )
  _ = try db.perform(
    .update(.tasks, id: id, fields: [.startTime: .null, .endTime: .null]), now: reminderNow)
  #expect(try db.snapshot().item(.tasks, id)?[.reminderEnabled] == .integer(0))
  #expect(taskReminderRows(snapshot: try db.snapshot(), now: reminderNow).isEmpty)
  _ = try db.perform(.delete(.tasks, id: id), now: reminderNow)
  #expect(taskReminderRows(snapshot: try db.snapshot(), now: reminderNow).isEmpty)
}

@Test func reminderFlagSurvivesSyncAndSharesSchedulingConflictGroup() throws {
  let a = try Fixture()
  let b = try Fixture()
  defer {
    a.clean()
    b.clean()
  }
  let source = try a.workspace()
  let target = try b.workspace()
  let id = try source.perform(
    .create(
      .tasks,
      fields: [
        .title: .string("同步提醒"),
        .plannedDate: .string("2026-10-28"), .startTime: .string("10:00"),
        .endTime: .string("11:00"),
        .reminderEnabled: .integer(1),
      ]), now: reminderNow
  ).id!
  try target.receive(source.pendingDocuments())
  #expect(try target.snapshot().item(.tasks, id)?[.reminderEnabled] == .integer(1))
  #expect(taskReminderRows(snapshot: try target.snapshot(), now: reminderNow).count == 1)
  let base = JSONValue.object(try source.db.record("tasks", id: id))
  var local = base
  var remote = base
  local["planned_date"] = .string("2026-10-29")
  remote["reminder_enabled"] = .integer(0)
  let (merged, conflict) = RecordMerge.workspace(base: base, local: local, remote: remote)
  #expect(conflict)
  #expect(
    merged["planned_date"] == remote["planned_date"] && merged["reminder_enabled"] == .integer(0))
}

@Test func version19ReminderUpgradeBacksUpAndPreservesIdentityAndMetadata() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let id = try db.perform(.create(.tasks, fields: [.title: .string("旧任务")]), now: reminderNow).id!
  let before = try db.db.one(
    "SELECT * FROM wb_sync_meta WHERE entity='tasks' AND id=?", [.string(id)])
  try db.db.script("ALTER TABLE tasks DROP COLUMN reminder_enabled; ALTER TABLE tasks DROP COLUMN reminder_at; PRAGMA user_version=19")
  try WorkspaceMigration.run(db.db)
  #expect(try db.db.one("PRAGMA user_version").values.first == .integer(21))
  #expect(try db.snapshot().item(.tasks, id)?[.reminderEnabled] == .integer(0))
  #expect(
    try db.db.one("SELECT * FROM wb_sync_meta WHERE entity='tasks' AND id=?", [.string(id)])
      == before)
  let folder = f.directory.appendingPathComponent("schema-backups")
  let backups = try FileManager.default.contentsOfDirectory(
    at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "sqlite" }
  #expect(backups.count == 1)
  // Validate the snapshot alone, without any transient SQLite sidecars.
  let standalone = f.directory.appendingPathComponent("standalone.sqlite")
  try FileManager.default.copyItem(at: backups[0], to: standalone)
  let backup = try SQLite(standalone, readOnly: true)
  #expect(try backup.one("PRAGMA user_version").values.first == .integer(19))
  #expect(try backup.record("tasks", id: id).text("title") == "旧任务")
  #expect(try !backup.columns("tasks").contains("reminder_enabled"))
  try WorkspaceMigration.run(db.db)
  #expect(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "sqlite" }.count == 1)
}

@MainActor private final class FakeReminderClient: ReminderNotificationClient {
  var allowed = true
  var requests: [String: LocalReminder] = [:]
  var addCount = 0
  var hold = false
  var gate: CheckedContinuation<Void, Never>?
  func authorized(requestPermission: Bool) async throws -> Bool { allowed }
  func pending() async -> [LocalReminder] { Array(requests.values) }
  func add(_ reminder: LocalReminder) async throws {
    if hold { await withCheckedContinuation { gate = $0 } }
    requests[reminder.id] = reminder
    addCount += 1
  }
  func remove(_ identifiers: [String]) { identifiers.forEach { requests[$0] = nil } }
}

@Test @MainActor func remindersReplaceWithoutDuplicatesAndCancelEvenAfterPermissionRevoked()
  async throws
{
  let client = FakeReminderClient()
  let service = WorkspaceReminders(client: client)
  let original = LocalReminder(
    id: "workbench-task:a", title: "A", body: "10:00", date: reminderNow.addingTimeInterval(3600))
  await service.reconcile([original])
  await service.reconcile([original])
  #expect(client.addCount == 1 && client.requests.count == 1)
  let moved = LocalReminder(
    id: original.id, title: "A", body: "11:00", date: original.date.addingTimeInterval(3600))
  await service.reconcile([moved])
  #expect(client.requests[original.id] == moved && client.requests.count == 1)
  client.allowed = false
  await service.reconcile([])
  #expect(client.requests.isEmpty && service.issue == nil)
  await service.reconcile([moved])
  #expect(client.requests.isEmpty && service.issue != nil)
  await #expect(throws: (any Error).self) { try await service.requestAuthorization() }
}

@Test @MainActor func cancellingDuringNotificationAddCannotResurrectOldReminder() async throws {
  let client = FakeReminderClient()
  client.hold = true
  let service = WorkspaceReminders(client: client)
  let reminder = LocalReminder(
    id: "workbench-task:a", title: "A", body: "", date: reminderNow.addingTimeInterval(3600))
  let first = Task { await service.reconcile([reminder]) }
  for _ in 0..<100 {
    if client.gate != nil { break }
    await Task.yield()
  }
  #expect(client.gate != nil)
  let cancel = Task { await service.reconcile([]) }
  for _ in 0..<5 { await Task.yield() }
  client.hold = false
  client.gate?.resume()
  await first.value
  await cancel.value
  #expect(client.requests.isEmpty)
}

@Test func tasksAndCoursesShareBudgetAndDisablingCoursesKeepsTasks() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let now = try Clock.parse("2026-09-14T07:00:00+08:00")
  _ = try db.perform(.installTimetable, now: now)
  for index in 0..<70 {
    let day = Clock.day(now.addingTimeInterval(Double(index) * 86400))
    _ = try db.perform(.create(.tasks, fields: [
      .title: .string("提醒 \(index)"), .plannedDate: .string(day),
      .startTime: .string("09:00"), .endTime: .string("10:00"),
      .reminderEnabled: .integer(1),
    ]), now: now)
  }
  let snapshot = try db.snapshot()
  let both = workspaceReminderPlan(snapshot: snapshot, now: now, courseMinutes: 10)
  #expect(both.count == 60)
  #expect(both.contains { $0.id.hasPrefix("workbench-task:") })
  #expect(both.contains { $0.id.hasPrefix("workbench-course:") })
  #expect(both.map(\.date) == both.map(\.date).sorted())
  let tasksOnly = workspaceReminderPlan(snapshot: snapshot, now: now, courseMinutes: 0)
  #expect(tasksOnly.count == 60)
  #expect(tasksOnly.allSatisfy { $0.id.hasPrefix("workbench-task:") })
}
