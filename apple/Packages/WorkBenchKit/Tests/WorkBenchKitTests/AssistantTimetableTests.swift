import Foundation
import Testing
@testable import WorkBenchKit

private func timetable() throws -> JSONValue {
  try JSONValue(json: """
    {"semester":{"title":"秋季测试学期","first_monday":"2026-09-07","weeks":16,
    "periods":[{"number":1,"start":"08:00","end":"08:45"},{"number":2,"start":"08:50","end":"09:35"}]},
    "courses":[{"title":"数学","teacher":"王老师","meetings":[
    {"weekday":1,"period_start":1,"period_end":2,"weeks":[1,3,5],"room":"101"}]}]}
    """)
}

@Test func timetablePreviewIsReadOnlyAndConfirmedImportIsIdempotent() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let now = Date.now
  let id = "wechat-" + String(repeating: "a", count: 64)
  let input = try timetable()
  let preview = try engine.prepareAssistantTimetable(input, requestID: id, now: now)
  #expect(preview["text"].string.contains("第一周周一：2026-09-07"))
  #expect(preview["text"].string.contains("周次 1、3、5"))
  #expect(try engine.prepareAssistantTimetable(input, requestID: id, now: now) == preview)
  #expect(try engine.snapshot()[.semesters].isEmpty)
  #expect(try engine.snapshot()[.courses].isEmpty)
  #expect(try engine.snapshot()[.courseMeetings].isEmpty)
  let first = try engine.commitAssistantPlan(id: id, now: now)
  let again = try engine.commitAssistantPlan(id: id, now: now)
  #expect(first == again)
  #expect(try engine.snapshot()[.semesters].count == 1)
  #expect(try engine.snapshot()[.courses].count == 1)
  #expect(try engine.snapshot()[.courseMeetings].count == 1)
  #expect(throws: WorkBenchError.self) {
    try engine.prepareAssistantTimetable(input, requestID: "duplicate", now: now)
  }
}

@Test func incompleteTimetableAndExpiredPreviewWriteNothing() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let now = Date.now
  var input = try timetable()
  let semester = input["semester"]
  var incomplete = semester
  incomplete["first_monday"] = .null
  input["semester"] = incomplete
  #expect(throws: WorkBenchError.self) {
    try engine.prepareAssistantTimetable(input, requestID: "incomplete", now: now)
  }
  input["semester"] = semester
  _ = try engine.prepareAssistantTimetable(input, requestID: "expires", now: now)
  #expect(throws: WorkBenchError.self) {
    try engine.commitAssistantPlan(id: "expires", now: now.addingTimeInterval(1801))
  }
  #expect(try engine.snapshot()[.semesters].isEmpty)
  #expect(try engine.snapshot()[.courses].isEmpty)
}

#if os(macOS)
@Test func workbookReadsSharedAndInlineTextWithCellAddresses() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  try FileManager.default.createDirectory(at: folder.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
  try Data("<sst><si><t>数学</t></si></sst>".utf8)
    .write(to: folder.appendingPathComponent("xl/sharedStrings.xml"))
  try Data("""
    <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c>
    <c r="C1" t="inlineStr"><is><t>周一</t></is></c></row></sheetData></worksheet>
    """.utf8).write(to: folder.appendingPathComponent("xl/worksheets/sheet1.xml"))
  let zip = Process()
  zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
  zip.arguments = ["-q", "fixture.xlsx", "xl/sharedStrings.xml", "xl/worksheets/sheet1.xml"]
  zip.currentDirectoryURL = folder
  try zip.run()
  zip.waitUntilExit()
  try #require(zip.terminationStatus == 0)
  let text = try TimetableWorkbook.read(Data(contentsOf: folder.appendingPathComponent("fixture.xlsx")))
  #expect(text.contains("A1=数学 | C1=周一"))
}
#endif

#if os(macOS)
@Test @MainActor func weChatTimetableRequiresExactConfirmationBeforeWriting() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let database = try WorkspaceDatabase(url: fixture.directory.appendingPathComponent("workbench.sqlite"))
  let store = WorkspaceStore(database: database)
  let session = AppSession(role: .workbench)
  let arguments = try timetable().json()
  let agent = Agent(workspace: { operation, arguments in
    await session.handleAssistant(operation, arguments, store: store)
  }, completion: { _ in
    .object(["tool_calls": .array([.object([
      "id": .string("preview"),
      "function": .object(["name": .string(AssistantContract.timetableTool), "arguments": .string(arguments)]),
    ])])])
  })
  let requestID = "wechat-" + String(repeating: "b", count: 64)
  let reply = try await agent.respond(to: "导入我的课表", image: nil, history: [], pending: nil, requestID: requestID)
  let pending = try #require(reply.pending)
  #expect(try await database.snapshot()[.semesters].isEmpty)
  _ = try await agent.respond(to: "确认 000", image: nil, history: [], pending: pending, requestID: requestID)
  #expect(try await database.snapshot()[.semesters].isEmpty)
  let confirmation = try await agent.respond(to: "确认 " + pending.code, image: nil, history: [], pending: pending, requestID: requestID)
  #expect(confirmation.text.contains("1 门课程"))
  #expect(store.snapshot[.semesters].count == 1)
  #expect(store.snapshot[.courses].count == 1)
}
#endif

@Test @MainActor func removingThoughtTagKeepsTextAndOtherTags() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let database = try WorkspaceDatabase(url: fixture.directory.appendingPathComponent("workbench.sqlite"))
  let store = WorkspaceStore(database: database)
  let editor = ThoughtEditing()
  let result = try await store.perform(.create(.reflections,
    fields: [.content: .string("要保留的正文"), .tags: .array([.string("移除"), .string("保留")])]))
  let id = try #require(result.id)
  editor.begin(try #require(store.snapshot.item(.reflections, id)))
  try await editor.removeTag("移除", from: store)
  let updated = try #require(store.snapshot.item(.reflections, id))
  #expect(updated[.content] == .string("要保留的正文"))
  #expect(thoughtTags(updated) == ["保留"])
  #expect(editor.buffers[id]?.tags == ["保留"])
}
