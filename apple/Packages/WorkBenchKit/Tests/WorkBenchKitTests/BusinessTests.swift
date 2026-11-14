import Foundation
import Testing

@testable import WorkBenchKit

struct Fixture {
  let directory: URL
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wb-native-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  func workspace() throws -> WorkspaceEngine {
    try WorkspaceEngine(url: directory.appendingPathComponent("workbench.sqlite"))
  }
  func photos() throws -> PhotoEngine {
    try PhotoEngine(url: directory.appendingPathComponent("photo.sqlite"))
  }
  func clean() { try? FileManager.default.removeItem(at: directory) }
  var space: JSONValue {
    .object([
      "id": .string("PhotoWorkspace_00000000-0000-4000-8000-000000000001"),
      "zone": .string("PhotoWorkspace_00000000-0000-4000-8000-000000000001"),
      "owner": .string("owner"), "account": .string("owner"), "scope": .string("private"),
      "container": .string("iCloud.io.github.coderzhh.workbenchpreview"), "environment": .string("Development"),
    ])
  }
}
let testNow = Date(timeIntervalSince1970: 1_792_886_400)
@Test func taskAssociationsAndImportanceAreAtomic() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let project = try db.perform(.create(.projects, fields: [.title: .string("项目")]), now: testNow)
    .id!
  let learning = try db.perform(.create(.learning, fields: [.title: .string("学习")]), now: testNow)
    .id!
  let task = try db.perform(
    .create(.tasks, fields: [.title: .string("任务"), .projectID: .string(project)]), now: testNow
  ).id!
  #expect(try db.db.record("tasks", id: task).integer("importance") == 1)
  #expect(throws: (any Error).self) {
    try db.perform(
      .update(.tasks, id: task, fields: [.learningID: .string(learning)]), now: testNow)
  }
  #expect(try db.db.record("tasks", id: task).text("project_id") == project)
  _ = try db.perform(.update(.tasks, id: task, fields: [.importance: .integer(5)]), now: testNow)
  let row = try db.db.record("tasks", id: task)
  #expect(
    row.integer("importance") == 5 && row.integer("important") == 0
      && row.text("priority") == "normal")
}
@Test func conversionReusesTaskAndCopiesAttachmentIdentity() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let note = try db.perform(
    .create(.notes, fields: [.content: .string("第一行\n详细内容"), .remark: .string("备注")]), now: testNow
  ).id!
  try db.db.insert(
    "attachments",
    [
      "id": .string("attachment-old"), "file_key": .string("same-file.jpg"), "name": .string("截图"),
      "mime": .string("image/jpeg"), "size": .integer(10), "sha256": .string("samehash"),
      "created_at": .string(Clock.stamp(testNow)), "note_id": .string(note),
    ])
  let first = try db.perform(.convertNote(id: note, plannedDate: Clock.day(testNow)), now: testNow)
    .id!
  let second = try db.perform(.convertNote(id: note, plannedDate: nil), now: testNow).id!
  #expect(first == second)
  #expect(try db.db.rows("SELECT * FROM tasks").count == 1)
  let attachment = try db.db.one("SELECT * FROM attachments WHERE task_id=?", [.string(first)])
  #expect(
    attachment.identifier != "attachment-old" && attachment.text("file_key") == "same-file.jpg")
  #expect(try db.db.record("tasks", id: first).text("notes") == "第一行\n详细内容\n\n备注")
}
@Test func duplicateFocusStartPausesAndResumesWithoutDuplication() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let first = try db.perform(.startFocus(taskID: nil), now: testNow)
  let repeated = try db.perform(.startFocus(taskID: nil), now: testNow.addingTimeInterval(5))
  #expect(first.id == repeated.id && repeated.alreadyRunning)
  #expect(try db.db.rows("SELECT * FROM focus_intervals").count == 1)
  _ = try db.perform(.pauseFocus, now: testNow.addingTimeInterval(300))
  let resumed = try db.perform(.startFocus(taskID: nil), now: testNow.addingTimeInterval(500))
  #expect(resumed.id == first.id)
  _ = try db.perform(
    .endFocus(id: first.id!, resumeHint: nil), now: testNow.addingTimeInterval(800))
  #expect(try db.db.record("focus_sessions", id: first.id!).integer("elapsed_seconds") == 600)
  #expect(try db.db.rows("SELECT * FROM focus_intervals").count == 2)
}
@Test func focusCorrectionPreservesPausesAndRejectsOverlap() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let id = try db.perform(.startFocus(taskID: nil), now: testNow).id!
  _ = try db.perform(.pauseFocus, now: testNow.addingTimeInterval(600))
  _ = try db.perform(.startFocus(taskID: nil), now: testNow.addingTimeInterval(900))
  _ = try db.perform(.endFocus(id: id, resumeHint: nil), now: testNow.addingTimeInterval(1800))
  let interval = try db.db.one("SELECT * FROM focus_intervals ORDER BY started_at LIMIT 1")
    .identifier
  #expect(throws: (any Error).self) {
    try db.perform(
      .correctFocus(
        id: id, intervalID: interval, start: testNow, end: testNow.addingTimeInterval(1000)),
      now: testNow.addingTimeInterval(2000))
  }
  _ = try db.perform(
    .correctFocus(
      id: id, intervalID: interval, start: testNow, end: testNow.addingTimeInterval(300)),
    now: testNow.addingTimeInterval(2000))
  #expect(try db.db.record("focus_sessions", id: id).integer("elapsed_seconds") == 1200)
}
@Test func activeTimerNeverEntersSync() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  _ = try db.perform(.startFocus(taskID: nil), now: testNow)
  #expect(
    try db.pendingDocuments().allSatisfy {
      $0.entity != "focus_sessions" && $0.entity != "focus_intervals"
    })
}
@Test func mainAcknowledgementRetainsConcurrentEdit() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let id = try db.perform(.create(.tasks, fields: [.title: .string("初稿")]), now: testNow).id!
  let pending = try db.pendingDocuments().first { $0.id == id }!
  _ = try db.perform(
    .update(.tasks, id: id, fields: [.title: .string("新修改")]), now: testNow.addingTimeInterval(1))
  try db.acknowledge(pending, serverFields: "server")
  #expect(
    try db.pendingDocuments().contains { $0.id == id && $0.payload["title"] == .string("新修改") })
}
@Test func mainSyncDefersForeignKeysAndDoesNotResurrectDeletedParent() throws {
  let a = try Fixture()
  let b = try Fixture()
  defer {
    a.clean()
    b.clean()
  }
  let source = try a.workspace()
  let target = try b.workspace()
  let project = try source.perform(
    .create(.projects, fields: [.title: .string("项目")]), now: testNow
  ).id!
  let task = try source.perform(
    .create(.tasks, fields: [.title: .string("任务"), .projectID: .string(project)]), now: testNow
  ).id!
  let documents = try source.pendingDocuments()
  let child = documents.first { $0.id == task }!
  let parent = documents.first { $0.id == project }!
  try target.receive([child])
  #expect(try target.db.rows("SELECT * FROM wb_sync_inbox").count == 1)
  try target.receive([parent])
  #expect(try target.db.record("tasks", id: task).text("project_id") == project)
  _ = try target.perform(.delete(.projects, id: project), now: testNow)
  try target.receive([child])
  #expect(try target.db.record("tasks", id: task)[value: "project_id"].isNull)
}
@Test func groupedMergeCannotProduceTwoAssociations() throws {
  let base: JSONValue = .object([
    "project_id": .null, "learning_id": .null, "course_id": .null, "title": .string("A"),
  ])
  var local = base
  var remote = base
  local["project_id"] = .string("p")
  remote["learning_id"] = .string("l")
  let (merged, conflict) = RecordMerge.workspace(base: base, local: local, remote: remote)
  #expect(conflict && merged["project_id"].isNull && merged["learning_id"] == .string("l"))
}
@Test func photoBrandOnlyAndSaveRetryAreCompatible() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.photos()
  try db.bind(f.space)
  var input = PhotoOrderInput()
  input.brand = "只填品牌"
  _ = try db.perform(.create(input), now: testNow)
  _ = try db.perform(.create(input), now: testNow)
  let orders = try db.snapshot().orders
  #expect(
    orders.count == 1 && orders[0].brand == "只填品牌" && orders[0][.postage].isNull
      && orders[0].images.isEmpty)
  let revision = orders[0].revision
  _ = try db.perform(
    .patch(id: input.id, field: .brand, before: .string("只填品牌"), value: .string("只填品牌")),
    now: testNow)
  #expect(try db.snapshot().orders[0].revision == revision)
}
@Test func photoPatchRetainsZeroAndRejectsStaleField() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.photos()
  try db.bind(f.space)
  var input = PhotoOrderInput()
  input.brand = "品牌"
  _ = try db.perform(.create(input), now: testNow)
  _ = try db.perform(
    .patch(id: input.id, field: .postage, before: .null, value: .integer(0)), now: testNow)
  #expect(try db.snapshot().orders[0][.postage] == .integer(0))
  #expect(throws: (any Error).self) {
    try db.perform(
      .patch(id: input.id, field: .postage, before: .null, value: .integer(200)), now: testNow)
  }
}
@Test func photoRoundTripAndAcknowledgementPreserveNewChanges() throws {
  let a = try Fixture()
  let b = try Fixture()
  defer {
    a.clean()
    b.clean()
  }
  let source = try a.photos()
  let target = try b.photos()
  try source.bind(a.space)
  try target.bind(a.space)
  var input = PhotoOrderInput()
  input.brand = "品牌"
  _ = try source.perform(.create(input), now: testNow)
  let pending = try source.pendingDocuments()
  try target.receive(pending)
  _ = try source.perform(
    .patch(id: input.id, field: .requirements, before: .string(""), value: .string("十张照片")),
    now: testNow)
  for doc in pending { try source.acknowledge(doc, serverFields: "server") }
  #expect(try target.snapshot().orders[0].brand == "品牌")
  #expect(
    try source.pendingDocuments().contains {
      $0.id == "order:" + input.id && $0.payload["requirements"] == .string("十张照片")
    })
}
@Test func photoPermanentDeleteCannotBeRevivedByOlderPeer() throws {
  let a = try Fixture()
  let b = try Fixture()
  defer {
    a.clean()
    b.clean()
  }
  let source = try a.photos()
  let target = try b.photos()
  try source.bind(a.space)
  try target.bind(a.space)
  var input = PhotoOrderInput()
  input.brand = "品牌"
  _ = try source.perform(.create(input), now: testNow)
  let old = try source.pendingDocuments()
  try target.receive(old)
  let order = try source.snapshot().orders[0]
  _ = try source.perform(.delete(id: input.id, expectedRevision: order.revision), now: testNow)
  try target.receive(source.pendingDocuments())
  try target.receive(old)
  #expect(try target.snapshot().orders.isEmpty)
  #expect(try target.pendingDocuments().contains { $0.payload["purged"].bool })
}
@Test func photoWorkflowAndAccountIsolation() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.photos()
  try db.bind(f.space)
  var other = f.space
  other["account"] = .string("someoneelse")
  #expect(throws: (any Error).self) { try db.bind(other) }
  var input = PhotoOrderInput()
  input.brand = "品牌"
  _ = try db.perform(.create(input), now: testNow)
  #expect(throws: (any Error).self) {
    try db.perform(.transition(id: input.id, stage: .completed, expectedRevision: 1), now: testNow)
  }
  _ = try db.perform(.transition(id: input.id, stage: .refund, expectedRevision: 1), now: testNow)
  _ = try db.perform(
    .transition(id: input.id, stage: .completed, expectedRevision: 2), now: testNow)
  #expect(try db.snapshot().orders[0].stage == .completed)
}
@Test func failedPhotoSaveCreatesNothingAndNoDraft() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.photos()
  try db.bind(f.space)
  #expect(throws: (any Error).self) { try db.perform(.create(.init()), now: testNow) }
  #expect(try db.snapshot().orders.isEmpty)
  #expect(try db.db.rows("SELECT * FROM photo_records").isEmpty)
  #expect(try db.db.rows("SELECT * FROM photo_drafts").isEmpty)
}
@Test func missingAttachmentDoesNotAdvanceRecords() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.photos()
  let id = UUID().uuidString.lowercased()
  let order = UUID().uuidString.lowercased()
  let doc = SyncDocument(
    id: "attachment:" + id, kind: "attachment", orderID: order,
    payload: .object([
      "id": .string(id), "order_id": .string(order), "file_key": .string(id + ".jpg"),
      "size": .integer(123), "sha256": .string("missing"),
    ]))
  #expect(throws: (any Error).self) { try db.receive([doc]) }
  #expect(try db.db.rows("SELECT * FROM photo_records").isEmpty)
}
@Test func defaultTimetableIsStableAndFrontiersNotSplit() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  _ = try db.perform(.installTimetable, now: testNow)
  let snapshot = try db.snapshot()
  _ = try db.perform(.installTimetable, now: testNow)
  #expect(snapshot[.courses].count == 9)
  #expect(try db.snapshot()[.courses].count == snapshot[.courses].count)
  let frontiers = try db.db.rows(
    "SELECT * FROM course_meetings WHERE course_id='course-2026-management-frontiers'")
  #expect(
    frontiers.count == 1 && frontiers[0].integer("period_start") == 1
      && frontiers[0].integer("period_end") == 4)
}
@Test func lessonCompletionAndScheduledTaskStayLinked() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let learning = try db.perform(.create(.learning, fields: [.title: .string("学习")]), now: testNow)
    .id!
  let lesson = try db.perform(
    .create(.lessons, fields: [.title: .string("第一步"), .learningID: .string(learning)]),
    now: testNow
  ).id!
  #expect(try db.db.rows("SELECT * FROM tasks").isEmpty)
  let task = try db.perform(
    .scheduleLesson(id: lesson, plannedDate: Clock.day(testNow)), now: testNow
  ).id!
  _ = try db.perform(.update(.tasks, id: task, fields: [.status: .string("done")]), now: testNow)
  #expect(try db.db.record("lessons", id: lesson).integer("done") == 1)
  _ = try db.perform(
    .update(.lessons, id: lesson, fields: [.title: .string("改名"), .done: .integer(0)]), now: testNow
  )
  #expect(try db.db.record("tasks", id: task).text("title") == "改名")
  #expect(try db.db.record("tasks", id: task).text("status") == "todo")
}
@Test func databaseBackupAndNewerVersionAreSafe() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  _ = try db.perform(.create(.tasks, fields: [.title: .string("保留 UUID")]), now: testNow)
  let backup = f.directory.appendingPathComponent("copy.sqlite")
  try db.db.backup(to: backup)
  #expect(try SQLite(backup, readOnly: true).rows("SELECT * FROM tasks").count == 1)
  try db.db.script("PRAGMA user_version=22")
  #expect(throws: (any Error).self) { try WorkspaceMigration.run(db.db) }
  #expect(try db.db.rows("SELECT * FROM tasks").count == 1)
}
@Test func moneyAndDatesRemainPrecise() throws {
  #expect(try Money.parse("") == nil)
  #expect(try Money.parse("0") == 0)
  #expect(try Money.parse("12.05") == 1205)
  #expect(throws: (any Error).self) { try Money.parse("12.005") }
  #expect(throws: (any Error).self) { try Validation.day(.string("2026-02-30")) }
  #expect(Clock.stamp(testNow).hasSuffix(".000Z"))
}
@Test func semesterUpdateCannotInvalidateExistingCourseMeetings() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  _ = try db.perform(.installTimetable, now: testNow)
  let term = try db.snapshot()[.semesters][0]
  #expect(throws: (any Error).self) {
    try db.perform(.update(.semesters, id: term.id, fields: [.weeks: .integer(4)]), now: testNow)
  }
  #expect(try db.snapshot()[.semesters][0][.weeks] == .integer(16))
}
@Test func lessonsCannotMoveIntoTheirDescendants() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let learning = try db.perform(.create(.learning, fields: [.title: .string("学习")]), now: testNow)
    .id!
  let parent = try db.perform(
    .create(.lessons, fields: [.title: .string("父"), .learningID: .string(learning)]), now: testNow
  ).id!
  let child = try db.perform(
    .create(
      .lessons,
      fields: [.title: .string("子"), .learningID: .string(learning), .parentID: .string(parent)]),
    now: testNow
  ).id!
  #expect(throws: (any Error).self) {
    try db.perform(
      .move(.lessons, id: parent, targetEntity: .lessons, targetID: child, placement: .inside),
      now: testNow)
  }
  #expect(try db.db.record("lessons", id: parent)[value: "parent_id"].isNull)
}
@Test func oldDefaultsUpgradeWithoutChangingIdentifiersOrMoney() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  _ = try db.perform(
    .create(.tasks, id: "original-task-id", fields: [.title: .string("原记录")]), now: testNow)
  try db.db.execute("UPDATE tasks SET importance=3,important=0,priority='normal'")
  try db.db.script("PRAGMA user_version=13")
  try WorkspaceMigration.run(db.db)
  #expect(try db.db.record("tasks", id: "original-task-id").integer("importance") == 1)
  #expect(try db.db.rows("PRAGMA foreign_key_check").isEmpty)
  #expect(try db.db.one("PRAGMA user_version").values.first == .integer(21))
}
@Test func metricImportPreservesNullsAndUpdatesSameCaptureOnly() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let account = try db.perform(
    .create(.accounts, fields: [.name: .string("视频账号"), .platform: .string("tiktok")]), now: testNow
  ).id!
  _ = try db.perform(
    .importMetrics(accountID: account, rows: [.init(videoID: "1", title: "视频", likes: 0)]),
    now: testNow)
  _ = try db.perform(
    .importMetrics(accountID: account, rows: [.init(videoID: "1", title: "更新", likes: 10)]),
    now: testNow)
  let rows = try db.db.rows("SELECT * FROM metrics")
  #expect(rows.count == 1 && rows[0].integer("likes") == 10 && rows[0][value: "plays"].isNull)
}
@Test func workspaceCommandsMatchStoredContract() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let now = try Clock.parse("2026-10-25T00:00:00.000Z")
  let project = try db.perform(.create(.projects, fields: [.title: .string("迁移契约项目")]), now: now)
    .id!
  let note = try db.perform(
    .create(.notes, fields: [.content: .string("迁移标题\n完整内容"), .projectID: .string(project)]),
    now: now
  ).id!
  _ = try db.perform(.update(.notes, id: note, fields: [.remark: .string("原备注")]), now: now)
  let task = try db.perform(.convertNote(id: note, plannedDate: nil), now: now).id!
  _ = try db.perform(.update(.tasks, id: task, fields: [.importance: .integer(5)]), now: now)
  let focus = try db.perform(.startFocus(taskID: task), now: now).id!
  _ = try db.perform(.pauseFocus, now: now.addingTimeInterval(300))
  _ = try db.perform(.startFocus(taskID: task), now: now.addingTimeInterval(600))
  _ = try db.perform(
    .update(.tasks, id: task, fields: [.status: .string("done")]), now: now.addingTimeInterval(1200)
  )
  var identifiers = [project: "project", note: "note", task: "task", focus: "focus"]
  for (index, row) in try db.db.rows("SELECT * FROM focus_intervals ORDER BY started_at")
    .enumerated()
  { identifiers[row.identifier] = "interval-" + String(index) }
  var actual: Record = [:]
  for (key, table) in [
    ("tasks", "tasks"), ("notes", "notes"), ("projects", "projects"), ("focus", "focus_sessions"),
    ("focusIntervals", "focus_intervals"),
  ] {
    actual[key] = .array(
      try db.db.rows(
        "SELECT * FROM \(quote(table)) ORDER BY \(table == "focus_intervals" ? "started_at" : "id")"
      ).map { row in
        var fields = row
        if table == "tasks" {
          // The frozen contract predates reminders. Check the additive default
          // separately while comparing every original field unchanged.
          #expect(fields.removeValue(forKey: "reminder_enabled") == .integer(0))
          #expect(fields.removeValue(forKey: "reminder_at") == .null)
        }
        for (key, value) in row where key == "id" || key.hasSuffix("_id") {
          if let replacement = identifiers[value.string] { fields[key] = .string(replacement) }
        }
        return .object(fields)
      })
  }
  let expected = try JSONValue(
    data: Data(
      contentsOf: Bundle.module.url(forResource: "workspace-contract", withExtension: "json")!))
  #expect(JSONValue.object(actual) == expected)
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["WORKBENCH_VERIFY_DB"] != nil))
func existingDatabaseCopyPreservesAllFieldsAndSyncMetadata() throws {
  let path = ProcessInfo.processInfo.environment["WORKBENCH_VERIFY_DB"]!
  let url = URL(fileURLWithPath: path)
  let raw = try SQLite(url)
  let names =
    WorkspaceEntity.allCases.map(\.rawValue) + [
      "wb_sync_meta", "wb_sync_settings", "wb_sync_conflicts", "wb_sync_inbox",
    ]
  var before: [String: [Record]] = [:]
  for name in names { before[name] = try raw.rows("SELECT * FROM \(quote(name)) ORDER BY rowid") }
  _ = try WorkspaceEngine(url: url)
  for name in names {
    let after = try raw.rows("SELECT * FROM \(quote(name)) ORDER BY rowid")
    if name == "wb_sync_conflicts" {
      for row in after {
        let old = try #require(before[name]?.first { $0.identifier == row.identifier })
        var preserved = row
        if old["base_payload"] == nil { preserved.removeValue(forKey: "base_payload") }
        try require(old == preserved, "迁移改变了保留版本的原始内容")
      }
      for old in before[name] ?? [] where !after.contains(where: { $0.identifier == old.identifier }) {
        let payload = try JSONValue(json: old.text("payload"))
        let current = try raw.record(old.text("entity"), id: old.text("record_id"))
        let equivalentCurrent = RecordMerge.equivalentWorkspace(payload, current.isEmpty ? .null : .object(current))
        let duplicate = try after.contains { kept in
          guard kept.text("entity") == old.text("entity") && kept.text("record_id") == old.text("record_id") else { return false }
          return RecordMerge.equivalentWorkspace(payload, try JSONValue(json: kept.text("payload")))
        }
        try require(equivalentCurrent || duplicate, "迁移移除了不同内容的保留版本")
      }
    } else { try require(before[name] == after, "迁移改变了 \(name) 原始内容") }
  }
  try require(try raw.rows("PRAGMA foreign_key_check").isEmpty, "迁移关联校验失败")
}
@Test func overlappingCalendarItemsReceiveAccurateLanes() {
  let event: (String, Int, Int) -> CalendarEntry = { id, start, end in
    .init(
      id: id, title: id, start: testNow.addingTimeInterval(Double(start)),
      end: testNow.addingTimeInterval(Double(end)),
      kind: .course(WorkspaceItem(entity: .courses, fields: [:])))
  }
  let lanes = calendarLanes([event("a", 0, 60), event("b", 20, 80), event("c", 80, 100)])
  #expect(
    lanes[0].count == 2 && lanes[1].count == 2 && lanes[0].lane != lanes[1].lane
      && lanes[2].count == 1)
}
@Test func photoImagesDeletePermanentlyAndStaleImagesCannotReviveOrder() throws {
  let a = try Fixture()
  let b = try Fixture()
  defer {
    a.clean()
    b.clean()
  }
  let source = try a.photos()
  let target = try b.photos()
  try source.bind(a.space)
  try target.bind(a.space)
  var input = PhotoOrderInput()
  input.brand = "带截图的订单"
  let png = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS2kAAAAASUVORK5CYII="
  )!
  let image = try source.importImage(data: png, name: "image.png", orderID: input.id)
  input.images = [image.id]
  _ = try source.perform(.create(input), now: testNow)
  let old = try source.pendingDocuments()
  try FileManager.default.copyItem(
    at: source.assets.appendingPathComponent(image.fileKey),
    to: target.assets.appendingPathComponent(image.fileKey))
  try target.receive(old)
  let order = try source.snapshot().orders[0]
  _ = try source.perform(.delete(id: order.id, expectedRevision: order.revision), now: testNow)
  #expect(
    !FileManager.default.fileExists(
      atPath: source.assets.appendingPathComponent(image.fileKey).path))
  try target.receive(source.pendingDocuments())
  try target.receive(old)
  #expect(try target.snapshot().orders.isEmpty)
  #expect(
    !FileManager.default.fileExists(
      atPath: target.assets.appendingPathComponent(image.fileKey).path))
}
@Test func photoSeparateFieldsMergeButSameFieldRemainsReviewable() throws {
  let a = try Fixture()
  let b = try Fixture()
  defer {
    a.clean()
    b.clean()
  }
  let source = try a.photos()
  let target = try b.photos()
  try source.bind(a.space)
  try target.bind(a.space)
  var input = PhotoOrderInput()
  input.brand = "品牌"
  _ = try source.perform(.create(input), now: testNow)
  let seed = try source.pendingDocuments()
  try target.receive(seed)
  for doc in seed { try source.acknowledge(doc, serverFields: "seed") }
  _ = try source.perform(
    .patch(id: input.id, field: .requirements, before: .string(""), value: .string("远端要求")),
    now: testNow)
  _ = try target.perform(
    .patch(id: input.id, field: .notes, before: .string(""), value: .string("本机备注")), now: testNow)
  try target.receive(source.pendingDocuments())
  #expect(try target.snapshot().conflicts.isEmpty)
  #expect(try target.snapshot().orders[0][.requirements] == .string("远端要求"))
  #expect(try target.snapshot().orders[0][.notes] == .string("本机备注"))
  _ = try source.perform(
    .patch(id: input.id, field: .notes, before: .string(""), value: .string("另一份备注")), now: testNow)
  try target.receive(source.pendingDocuments())
  #expect(try !target.snapshot().conflicts.isEmpty)
}
@Test func sqliteTextPreservesEmbeddedNullAndUnicode() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let original = "中文\u{0000}保留🎞️"
  _ = try db.perform(
    .create(.notes, id: "text-fidelity", fields: [.content: .string(original)]), now: testNow)
  #expect(try db.db.record("notes", id: "text-fidelity").text("content") == original)
}
@Test func nativeCourseNotificationsUseShanghaiScheduleAndLimit() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  _ = try db.perform(.installTimetable, now: testNow)
  let rows = courseReminderRows(
    snapshot: try db.snapshot(), now: try Clock.parse("2026-09-14T00:00:00.000Z"), minutes: 10)
  #expect(!rows.isEmpty && rows.count <= 60)
  #expect(
    rows.allSatisfy {
      $0["id"].string.hasPrefix("workbench-course:") && $0["at"].string.hasSuffix("Z")
    })
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["WORKBENCH_VERIFY_PHOTO_DB"] != nil))
func existingPhotoCopyPreservesPayloadsMoneyAndSyncVersions() throws {
  let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKBENCH_VERIFY_PHOTO_DB"]!)
  let raw = try SQLite(url)
  let tables = [
    "photo_records", "photo_settings", "photo_drafts", "photo_generation", "photo_garbage",
  ]
  var before: [String: [Record]] = [:]
  for table in tables {
    before[table] = try raw.rows("SELECT * FROM \(quote(table)) ORDER BY rowid")
  }
  _ = try PhotoEngine(url: url)
  let previousRecords = before["photo_records"] ?? []
  let currentRecords = try raw.rows("SELECT * FROM photo_records ORDER BY rowid")
  try require(previousRecords.map(\.identifier) == currentRecords.map(\.identifier), "拍照迁移改变了记录身份")
  var reconciled = false
  for table in tables {
    let after = try raw.rows("SELECT * FROM \(quote(table)) ORDER BY rowid")
    if table == "photo_records" {
      for (old, current) in zip(previousRecords, currentRecords) where old != current {
        try require(!old[value: "conflict"].isNull && current[value: "conflict"].isNull,
          "拍照迁移改变了无冲突的记录")
        let remote = try JSONValue(json: old.text("conflict"))
        let merged = try #require(RecordMerge.photo(kind: old.text("kind"),
          base: JSONValue(json: old.text("base")), local: JSONValue(json: old.text("payload")), remote: remote["payload"]))
        var expected = old
        expected["payload"] = .string(try merged.json())
        expected["base"] = .string(try remote["payload"].json())
        expected["server"] = remote["serverFields"]
        expected["dirty"] = .integer(merged == remote["payload"] ? 0 : 1)
        expected["revision"] = .integer(old.integer("revision") + 1)
        expected["conflict"] = .null
        try require(current == expected, "拍照迁移没有完整保留合并内容与同步元数据")
        reconciled = true
      }
    } else if table == "photo_generation" {
      let old = try #require(before[table]?.first)
      try require(after.first?.integer("value") == old.integer("value") + (reconciled ? 1 : 0), "拍照刷新版本异常")
    } else { try require(before[table] == after, "拍照迁移改变了 \(table) 原始内容") }
  }
}
