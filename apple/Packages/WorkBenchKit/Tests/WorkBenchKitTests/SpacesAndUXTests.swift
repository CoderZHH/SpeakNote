import Foundation
import Testing

@testable import WorkBenchKit

@Test func customSpacesCollectionsLessonsAndAssociationsWorkEndToEnd() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()

  // Fresh workspace does not force hardcoded spaces.
  #expect(try db.snapshot()[.spaces].isEmpty)

  let lifeSpace = try db.perform(
    .create(
      .spaces,
      fields: [
        .title: .string("生活"), .symbol: .string("leaf"),
        .color: .string("green"), .allowsLessons: .integer(1),
      ]),
    now: testNow
  ).id!
  let workSpace = try db.perform(
    .create(
      .spaces,
      fields: [
        .title: .string("副业"), .symbol: .string("sparkles"),
        .color: .string("orange"), .allowsLessons: .integer(0),
      ]),
    now: testNow
  ).id!

  // Reorder custom spaces.
  _ = try db.perform(
    .move(.spaces, id: workSpace, targetEntity: .spaces, targetID: lifeSpace, placement: .before),
    now: testNow)
  let orderedSpaces = try db.snapshot()[.spaces].sorted { $0[.position].int < $1[.position].int }
  #expect(orderedSpaces.map(\.id) == [workSpace, lifeSpace])

  // Create collection card inside custom space.
  let podcastCard = try db.perform(
    .create(.collections, fields: [.spaceID: .string(workSpace), .title: .string("独立播客")]),
    now: testNow
  ).id!
  let stepID = try db.perform(
    .create(.lessons, fields: [.collectionID: .string(podcastCard), .title: .string("录制第一期 Demo")]),
    now: testNow
  ).id!

  // Schedule step into Today tasks and verify bidirectional completion sync.
  let scheduledTask = try db.perform(
    .scheduleLesson(id: stepID, plannedDate: Clock.day(testNow)),
    now: testNow
  ).id!
  var snapshot = try db.snapshot()
  let taskItem = try #require(snapshot.item(.tasks, scheduledTask))
  #expect(snapshot.association(taskItem)?.id == podcastCard)
  #expect(snapshot.collectionSymbol(snapshot.association(taskItem)!) == "sparkles")

  _ = try db.perform(.update(.tasks, id: scheduledTask, fields: [.status: .string("done")]), now: testNow)
  #expect(try db.db.record("lessons", id: stepID).integer("done") == 1)

  // Convert note associated with custom collection preserves collection_id.
  let noteID = try db.perform(
    .create(
      .notes,
      fields: [.content: .string("剪辑片头音乐\n30秒环境音"), .collectionID: .string(podcastCard)]),
    now: testNow
  ).id!
  let convertedID = try db.perform(
    .convertNote(id: noteID, plannedDate: Clock.day(testNow)),
    now: testNow
  ).id!
  snapshot = try db.snapshot()
  #expect(snapshot.item(.tasks, convertedID)?[.collectionID] == .string(podcastCard))

  // Deleting the custom space removes its collections while preserving tasks safely (ON DELETE SET NULL).
  _ = try db.perform(.delete(.spaces, id: workSpace), now: testNow)
  snapshot = try db.snapshot()
  #expect(snapshot.item(.collections, podcastCard) == nil)
  #expect(snapshot.item(.tasks, convertedID) != nil)
  #expect(snapshot.item(.tasks, convertedID)?[.collectionID].isNull == true)
}

@Test func migrationFromV21CreatesSpacesOnlyForPopulatedLegacyEntities() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()

  let projectID = try db.perform(
    .create(.projects, id: "legacy-proj-1", fields: [.title: .string("老项目")]),
    now: testNow
  ).id!
  let taskID = try db.perform(
    .create(.tasks, id: "legacy-task-1", fields: [.title: .string("老任务"), .projectID: .string(projectID)]),
    now: testNow
  ).id!

  // Simulate upgrading from a real v21 database whose `lessons` table still had `learning_id TEXT NOT NULL ... , title TEXT NOT NULL`
  // and `attachments` had the old 5-column CHECK constraint.
  try db.db.script("PRAGMA foreign_keys=OFF")
  try db.db.script("""
    DROP TABLE spaces;
    DROP TABLE collections;
    DROP TABLE lessons;
    CREATE TABLE lessons (
      id TEXT PRIMARY KEY, learning_id TEXT NOT NULL REFERENCES learning(id) ON DELETE CASCADE,
      title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
      task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
      parent_id TEXT REFERENCES lessons(id) ON DELETE CASCADE
    );
    DROP TABLE attachments;
    CREATE TABLE attachments (
      id TEXT PRIMARY KEY, file_key TEXT NOT NULL, name TEXT NOT NULL, mime TEXT NOT NULL,
      size INTEGER NOT NULL CHECK(size>0 AND size<=104857600), sha256 TEXT NOT NULL, created_at TEXT NOT NULL,
      task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
      note_id TEXT REFERENCES notes(id) ON DELETE CASCADE,
      project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
      learning_id TEXT REFERENCES learning(id) ON DELETE CASCADE,
      course_id TEXT REFERENCES courses(id) ON DELETE CASCADE,
      CHECK((task_id IS NOT NULL)+(note_id IS NOT NULL)+(project_id IS NOT NULL)+(learning_id IS NOT NULL)+(course_id IS NOT NULL)=1)
    );
    PRAGMA user_version=21;
    """)
  try db.db.script("PRAGMA foreign_keys=ON")
  try WorkspaceMigration.run(db.db)

  let snapshot = try db.snapshot()
  #expect(snapshot[.spaces].count == 1)
  let migratedSpace = try #require(snapshot[.spaces].first)
  #expect(migratedSpace.title == "项目")
  #expect(migratedSpace[.legacyEntity] == .string("projects"))
  #expect(snapshot.item(.projects, projectID)?.title == "老项目")
  #expect(snapshot.association(try #require(snapshot.item(.tasks, taskID)))?.id == projectID)

  // Verify upgraded `lessons` table now accepts collection-owned steps without `learning_id`.
  let newSpace = try db.perform(.create(.spaces, fields: [.title: .string("阅读")]), now: testNow).id!
  let newCard = try db.perform(
    .create(.collections, fields: [.spaceID: .string(newSpace), .title: .string("设计心理学")]),
    now: testNow
  ).id!
  let newLesson = try db.perform(
    .create(.lessons, fields: [.collectionID: .string(newCard), .title: .string("第一章")]),
    now: testNow
  ).id!
  #expect(!newLesson.isEmpty)
}

@Test func taskScheduleSupportsOptionalPlannedDateAndDeadline() throws {
  let now = try Clock.parse("2026-11-18T09:00:00+08:00")
  var schedule = TaskScheduleValues(now: now)
  schedule.hasPlannedDate = false
  schedule.hasDueDate = true
  schedule.dueDate = try Clock.parse("2026-11-25T00:00:00+08:00")

  let fields = try schedule.fields(now: now)
  #expect(fields[.plannedDate] == .null)
  #expect(fields[.dueDate] == .string("2026-11-25"))
  #expect(schedule.summary == "以后 · 11/25 截止")

  let restoredItem = WorkspaceItem(
    entity: .tasks,
    fields: [
      "id": .string("due-test"), "title": .string("交初稿"),
      "status": .string("todo"), "planned_date": .null, "due_date": .string("2026-11-25"),
    ])
  let restored = TaskScheduleValues(item: restoredItem, now: now)
  #expect(!restored.hasPlannedDate)
  #expect(restored.hasDueDate && Clock.day(restored.dueDate) == "2026-11-25")

  // Future-planned task is NOT due for today, so moving it into Today sets today's date instead of clearing it.
  let futureTask = WorkspaceItem(
    entity: .tasks,
    fields: [
      "id": .string("future-task"), "title": .string("下周汇报"),
      "status": .string("todo"), "planned_date": .string("2026-11-25"),
    ])
  #expect(!isTaskDueForToday(futureTask, day: "2026-11-18"))
}

@Test func assistantCreatesCustomSpaceCollectionAndTaskInOneBatch() throws {
  let f = try Fixture()
  defer { f.clean() }
  let engine = try f.workspace()

  let batch: JSONValue = .array([
    .object([
      "kind": .string("create"), "entity": .string("spaces"), "ref": .string("side_space"),
      "fields": .object([
        "title": .string("副业"), "symbol": .string("sparkles"),
        "color": .string("orange"),
      ]),
    ]),
    .object([
      "kind": .string("create"), "entity": .string("collections"), "ref": .string("card"),
      "fields": .object(["space_id": .string("@side_space"), "title": .string("独立应用")]),
    ]),
    .object([
      "kind": .string("create"), "entity": .string("tasks"),
      "fields": .object(["title": .string("设计图标"), "collection_id": .string("@card")]),
    ]),
  ])

  _ = try engine.applyAssistantChanges(batch, requestID: "custom-space-batch", attachments: [], now: testNow)
  let snapshot = try engine.snapshot()
  #expect(snapshot[.spaces].count == 1)
  #expect(snapshot[.collections].count == 1)
  let task = try #require(snapshot[.tasks].first)
  #expect(snapshot.association(task)?.title == "独立应用")

  let searched = try engine.assistantSearch(.object(["entity": .string("spaces")]), now: testNow)
  #expect(searched["items"].array.first?["fields"]["title"] == .string("副业"))
}

@Test func defaultDataLocationIsIsolatedFromWorkBench() throws {
  unsetenv("SPEAKNOTE_DB_PATH")
  unsetenv("SPEAKNOTE_WORKSPACE_ROOT")
  unsetenv("WORKBENCH_DB_PATH")
  unsetenv("WORKBENCH_WORKSPACE_ROOT")
  let location = try DataLocation.current(role: .workbench)
  #expect(location.directory.lastPathComponent == "SpeakNote")
  #expect(!location.directory.path.contains("WorkBench Preview"))
}

#if os(macOS)
  import AppKit

  @MainActor
  @Test func menuBarBrandMarkRendersTemplateIconMatchingAppLogoOrientation() throws {
    let icon = SpeakNoteBrandMark.menuBarImage(dimmed: false, description: "随口记快捷面板")
    #expect(icon.isTemplate)
    #expect(icon.size == NSSize(width: 18, height: 18))
    #expect(icon.accessibilityDescription == "随口记快捷面板")

    // Render into a 72x72 top-origin RGBA buffer via NSGraphicsContext to verify upright orientation
    let px = 72
    var buffer = [UInt8](repeating: 0, count: px * px * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let cgCtx = try #require(
      CGContext(
        data: &buffer,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: px * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()

    func alphaAt(normX: Double, normYFromTop: Double) -> UInt8 {
      // In CGContext memory, row 0 is the TOP of the unflipped CGBitmapContext!
      let x = min(px - 1, max(0, Int(normX * Double(px))))
      let y = min(px - 1, max(0, Int(normYFromTop * Double(px))))
      return buffer[(y * px + x) * 4 + 3]
    }

    // Center voice waveform bar (~0.50, ~0.52 from top) must be opaque
    #expect(alphaAt(normX: 0.50, normYFromTop: 0.52) > 180)
    // Top-right folded corner (~0.72, ~0.25 from top) must be opaque, while lower-right gap (~0.72, ~0.70) is empty
    #expect(alphaAt(normX: 0.72, normYFromTop: 0.25) > 200)
    #expect(alphaAt(normX: 0.72, normYFromTop: 0.70) == 0)
  }
#endif

@Test func coursePaletteSnapsToMondayAndBuildsValidStandardSemester() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  let wednesday = try Clock.parse("2026-09-09T15:30:00+08:00")
  let monday = CoursePalette.snapToMonday(wednesday)
  #expect(Clock.day(monday) == "2026-09-07")
  #expect(CoursePalette.weekRangeSummary([1, 2, 3, 5, 7, 8]) == "第 1–3、5、7–8 周")

  let engine = try WorkspaceEngine(url: dir.appendingPathComponent("courses.sqlite"))
  let periods = CoursePalette.standardPeriods(count: 10)
  #expect(periods.count == 10)

  let semResult = try engine.perform(
    .create(
      .semesters,
      fields: [
        .title: .string("2026 秋季学期"),
        .firstMonday: .string(Clock.day(monday)),
        .weeks: .integer(16),
        .periods: .array(periods),
      ]),
    now: wednesday
  )
  let semID = try #require(semResult.id)

  let courseResult = try engine.perform(
    .create(
      .courses,
      fields: [
        .title: .string("交互设计"),
        .semesterID: .string(semID),
        .color: .string("#6e5dc6"),
      ]),
    now: wednesday
  )
  let courseID = try #require(courseResult.id)

  _ = try engine.perform(
    .create(
      .courseMeetings,
      fields: [
        .courseID: .string(courseID),
        .weekday: .integer(3),
        .periodStart: .integer(3),
        .periodEnd: .integer(4),
        .weeks: .array((1...16).map { .integer(Int64($0)) }),
        .room: .string("设计楼 302"),
      ]),
    now: wednesday
  )

  let snap = try engine.snapshot()
  #expect(snap.item(.courses, courseID)?[.color].string == "#6e5dc6")
  let occ = courseOccurrences(snapshot: snap, day: wednesday)
  #expect(occ.count == 1)
  #expect(occ.first?.start == "10:00")
  #expect(occ.first?.end == "11:40")
}

@Test func focusSupportsPomodoroGoalUpdateAndCleanDiscard() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  let engine = try WorkspaceEngine(url: dir.appendingPathComponent("focus-goal.sqlite"))
  let start = try Clock.parse("2026-11-18T10:00:00+08:00")
  let focusID = try #require(
    try engine.perform(.startFocus(taskID: nil, goalSeconds: 1500), now: start).id
  )

  var snap = try engine.snapshot()
  let pres1 = try #require(FocusPresentation.current(in: snap))
  #expect(pres1.timer.goalSeconds == 1500)
  #expect(pres1.timer.remaining(at: start.addingTimeInterval(300)) == 1200)
  #expect(pres1.timer.progress(at: start.addingTimeInterval(750)) == 0.5)

  // Live switch to 45m mid-session
  _ = try engine.perform(.updateFocusGoal(id: focusID, goalSeconds: 2700), now: start.addingTimeInterval(300))
  snap = try engine.snapshot()
  let pres2 = try #require(FocusPresentation.current(in: snap))
  #expect(pres2.timer.goalSeconds == 2700)

  // Discard session ("放弃本次计时"): leaves zero sessions and zero intervals
  _ = try engine.perform(.delete(.focusSessions, id: focusID), now: start.addingTimeInterval(310))
  snap = try engine.snapshot()
  #expect(FocusPresentation.current(in: snap) == nil)
  #expect(snap[.focusSessions].isEmpty)
  #expect(snap[.focusIntervals].isEmpty)
}

#if os(macOS)
  @Test func assistantCredentialsStoreLocallyWithOwnerOnlyPermissionsWithoutKeychain() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let local = AssistantLocal(workspaceDirectory: dir)
    let files = AssistantFiles(local: local)

    // Before opt-in, load returns nil without creating assistant directory
    let initial: String? = try files.load("deepseek.json")
    #expect(initial == nil)
    #expect(!FileManager.default.fileExists(atPath: local.directory.path))

    // Saving creates 0700 directory + 0600 file excluded from backup
    try files.save("sk-test-1234567890abcdef", to: "deepseek.json", excludeFromBackup: true)
    let loaded: String? = try files.load("deepseek.json")
    #expect(loaded == "sk-test-1234567890abcdef")

    let dirPerms = try FileManager.default.attributesOfItem(atPath: local.directory.path)[.posixPermissions] as? Int
    let fileURL = local.directory.appendingPathComponent("deepseek.json")
    let filePerms = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
    #expect(dirPerms == 0o700)
    #expect(filePerms == 0o600)

    try files.remove("deepseek.json")
    let afterRemove: String? = try files.load("deepseek.json")
    #expect(afterRemove == nil)
  }
#endif
