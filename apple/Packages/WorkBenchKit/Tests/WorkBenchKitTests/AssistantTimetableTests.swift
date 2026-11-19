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
  #expect(preview["text"].string.contains("开学：2026-09-07（周一）"))
  #expect(preview["text"].string.contains("1、3、5周"))
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
  #expect(!reply.text.contains(pending.code))
  #expect(reply.text.contains("回复「确认」"))
  #expect(try await database.snapshot()[.semesters].isEmpty)
  _ = try await agent.respond(to: "确认 000", image: nil, history: [], pending: pending, requestID: requestID)
  #expect(try await database.snapshot()[.semesters].isEmpty)
  let confirmation = try await agent.respond(to: "确认", image: nil, history: [], pending: pending, requestID: requestID)
  #expect(confirmation.text.contains("1 门课程"))
  #expect(store.snapshot[.semesters].count == 1)
  #expect(store.snapshot[.courses].count == 1)
}

@Test func timetablePreviewFormatsRangesSinglePeriodsAndBucketsCleanly() throws {
  #expect(compactAssistantWeeks([9, 10, 11, 12, 13, 14, 15, 16]) == "9–16周")
  #expect(compactAssistantWeeks([8]) == "第8周")
  #expect(compactAssistantWeeks([1, 3, 5, 7, 9, 11]) == "1–11单周")
  #expect(compactAssistantWeeks([2, 4, 6, 8]) == "2–8双周")

  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let fullJSON = try JSONValue(json: """
    {"semester":{"title":"2026-2027学年 秋季学期","first_monday":"2026-09-14","weeks":16,
    "periods":[
      {"number":1,"start":"08:00","end":"08:45"},{"number":2,"start":"08:55","end":"09:40"},
      {"number":3,"start":"10:00","end":"10:45"},{"number":4,"start":"10:55","end":"11:40"},
      {"number":5,"start":"13:00","end":"13:45"},{"number":6,"start":"13:55","end":"14:40"},
      {"number":7,"start":"15:00","end":"15:45"},{"number":8,"start":"15:55","end":"16:40"},
      {"number":9,"start":"18:00","end":"18:45"},{"number":10,"start":"18:55","end":"19:40"},
      {"number":11,"start":"20:00","end":"20:45"}
    ]},
    "courses":[
      {"title":"大数据与人工智能（硕士）01","code":"01","teacher":"方冰","meetings":[
        {"weekday":1,"period_start":3,"period_end":4,"weeks":[9,10,11,12,13,14,15,16],"room":"2-111"}
      ]},
      {"title":"学术英语写作与交流（硕士）57","teacher":"刘婷","meetings":[
        {"weekday":4,"period_start":4,"period_end":4,"weeks":[9,10,11,12,13,14,15,16],"room":"1-213"}
      ]}
    ]}
    """)
  let preview = try engine.prepareAssistantTimetable(
    fullJSON, requestID: "wechat-" + String(repeating: "c", count: 64), now: .now)
  let text = preview["text"].string
  #expect(text.contains("作息：共 11 节（上午 08:00–11:40 / 下午 13:00–16:40 / 晚上 18:00–20:45）"))
  #expect(text.contains("周一 3–4节 · 9–16周 · 2-111"))
  #expect(text.contains("周四 第4节 · 9–16周 · 1-213"))
  #expect(!text.contains("第4–4节"))
}

@Test func assistantManagesAndDeletesSemestersCoursesAndMeetings() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let now = Date.now

  // 1. Create semester + course + meeting via applyAssistantChanges batch
  let createBatch: JSONValue = .array([
    .object([
      "kind": .string("create"), "entity": .string("semesters"), "ref": .string("sem"),
      "fields": .object([
        "title": .string("2026 秋"),
        "first_monday": .string("2026-09-14"),
        "weeks": .integer(16),
        "periods": .array([
          .object(["number": .integer(1), "start": .string("08:00"), "end": .string("08:45")]),
          .object(["number": .integer(2), "start": .string("08:55"), "end": .string("09:40")]),
        ]),
      ]),
    ]),
    .object([
      "kind": .string("create"), "entity": .string("courses"), "ref": .string("crs"),
      "fields": .object([
        "semester_id": .string("@sem"),
        "title": .string("高级运筹学"),
        "teacher": .string("周文坤"),
      ]),
    ]),
    .object([
      "kind": .string("create"), "entity": .string("course_meetings"),
      "fields": .object([
        "course_id": .string("@crs"),
        "weekday": .integer(1),
        "period_start": .integer(1),
        "period_end": .integer(2),
        "weeks": .array([.integer(1), .integer(2), .integer(3)]),
        "room": .string("2-112"),
      ]),
    ]),
  ])
  _ = try engine.applyAssistantChanges(createBatch, requestID: "sem-batch-1", attachments: [], now: now)
  #expect(try engine.snapshot()[.semesters].count == 1)
  #expect(try engine.snapshot()[.courses].count == 1)
  #expect(try engine.snapshot()[.courseMeetings].count == 1)

  // 2. Search semester & update its title
  let searched = try engine.assistantSearch(.object(["entity": .string("semesters")]), now: now)
  let semEntry = try #require(searched["items"].array.first)
  let semID = semEntry["fields"]["id"].string
  let semVer = semEntry["version"].string

  _ = try engine.applyAssistantChanges(
    .array([
      .object([
        "kind": .string("update"), "entity": .string("semesters"),
        "target_id": .string(semID), "expected_version": .string(semVer),
        "fields": .object(["title": .string("2026-2027 秋季学期")]),
      ])
    ]),
    requestID: "sem-update-1", attachments: [], now: now
  )
  #expect(try engine.snapshot().item(.semesters, semID)?.title == "2026-2027 秋季学期")

  // 3. Delete semester via AI (cascades courses & meetings)
  let refreshed = try #require(
    try engine.assistantSearch(.object(["entity": .string("semesters")]), now: now)["items"].array.first
  )
  let deleteReceipt = try engine.applyAssistantChanges(
    .array([
      .object([
        "kind": .string("delete"), "entity": .string("semesters"),
        "target_id": .string(semID), "expected_version": refreshed["version"],
      ])
    ]),
    requestID: "sem-delete-1", attachments: [], now: now
  )
  #expect(deleteReceipt["items"].array.first?["summary"].string.contains("删除学期") == true)
  #expect(try engine.snapshot()[.semesters].isEmpty)
  #expect(try engine.snapshot()[.courses].isEmpty)
  #expect(try engine.snapshot()[.courseMeetings].isEmpty)
}

@Test func agentAcceptsAndProcessesMultipleImagesTogether() async throws {
  actor ImageCollector {
    var urls: [String] = []
    func append(_ url: String) { urls.append(url) }
    func get() -> [String] { urls }
  }
  let collector = ImageCollector()
  let fixture = try Fixture()
  defer { fixture.clean() }
  let database = try WorkspaceDatabase(url: fixture.directory.appendingPathComponent("workbench.sqlite"))
  let agent = Agent(workspace: { op, args in
    if op == "apply" {
      let result = try await database.applyAssistantChanges(args["changes"], requestID: args["request_id"].string, attachments: [])
      return .object(["result": result])
    }
    return .object(["result": .null])
  }, completion: { messages in
    let userMsg = messages.first { $0["role"] == .string("user") }
    if let parts = userMsg?["content"].array {
      for part in parts {
        if part["type"] == .string("image_url") {
          let url = part["image_url"]["url"].string
          if !url.isEmpty {
            await collector.append(url)
          }
        }
      }
    }
    return .object([
      "role": .string("assistant"),
      "tool_calls": .array([.object([
        "id": .string("call-1"),
        "function": .object([
          "name": .string(AssistantContract.applyTool),
          "arguments": .string("""
            {"changes":[
              {"kind":"create","entity":"tasks","fields":{"title":"处理发票1"}},
              {"kind":"create","entity":"tasks","fields":{"title":"处理发票2"}}
            ]}
          """),
        ]),
      ])]),
    ])
  })

  let dummyImg1 = "data:image/jpeg;base64,AAAA"
  let dummyImg2 = "data:image/jpeg;base64,BBBB"
  let pendingNil: PendingChange? = nil
  let reply = try await agent.respond(
    to: "帮我根据这两张发票建两个任务",
    images: [dummyImg1, dummyImg2],
    history: [],
    pending: pendingNil,
    requestID: "wechat-" + String(repeating: "c", count: 64)
  )

  let urls = await collector.get()
  #expect(urls.count == 2)
  #expect(urls == [dummyImg1, dummyImg2])
  #expect(reply.text.contains("已保存") || reply.text.contains("处理发票"))
  let tasks = try await database.snapshot()[.tasks]
  #expect(tasks.count == 2)
}

@Test func naturalLanguageWithConfirmationPrefixIsDeliveredToAgentWhenNoPending() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  actor PromptCollector {
    var prompt = ""
    func set(_ val: String) { prompt = val }
    func get() -> String { prompt }
  }
  let collector = PromptCollector()
  let agent = Agent(workspace: { _, _ in .object(["result": .null]) }, completion: { messages in
    if let userMsg = messages.first(where: { $0["role"] == .string("user") }) {
      await collector.set(userMsg["content"].string)
    }
    return .object([
      "role": .string("assistant"),
      "content": .string("已收到你的确认：9.14 开学并删除旧学期。")
    ])
  })

  let reply = try await agent.respond(
    to: "确认 9.14 确认删除",
    images: [],
    history: [],
    pending: nil,
    requestID: "test-confirm-dispatch"
  )

  let received = await collector.get()
  #expect(received == "确认 9.14 确认删除")
  #expect(reply.text.contains("已收到你的确认"))
  #expect(!reply.text.contains("当前没有待确认的操作"))
}

@Test func timetableImportCanAtomicallyReplaceOldSemester() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  let oldSemFields: [ItemField: JSONValue] = [
    .title: .string("旧学期"),
    .firstMonday: .string("2026-09-07"),
    .weeks: .integer(16),
    .periods: .array([
      .object(["number": .integer(1), "start": .string("08:00"), "end": .string("08:45")])
    ]),
  ]
  let oldSemID = try engine.perform(.create(.semesters, fields: oldSemFields), now: now).id!
  #expect(try engine.snapshot().item(.semesters, oldSemID) != nil)

  let input = try JSONValue(json: """
    {
      "replace_semester_id": "\(oldSemID)",
      "semester": {
        "title": "2026-2027学年 秋季学期",
        "first_monday": "2026-09-14",
        "weeks": 16,
        "periods": [
          {"number": 1, "start": "08:00", "end": "08:45"},
          {"number": 2, "start": "08:55", "end": "09:40"}
        ]
      },
      "courses": [
        {
          "title": "大数据与人工智能",
          "meetings": [
            {"weekday": 1, "period_start": 1, "period_end": 2, "weeks": [1, 2, 3]}
          ]
        }
      ]
    }
  """)

  let preview = try engine.prepareAssistantTimetable(input, requestID: "replace-test", now: now)
  let text = preview["text"].string
  #expect(text.contains("将删除旧学期「旧学期」"))
  #expect(text.contains("2026-2027学年 秋季学期"))

  #expect(try engine.snapshot().item(.semesters, oldSemID) != nil)

  let commitReceipt = try engine.commitAssistantPlan(id: "replace-test", now: now)
  #expect(commitReceipt["status"] == .string("succeeded"))

  let snapshot = try engine.snapshot()
  #expect(snapshot.item(.semesters, oldSemID) == nil)
  let newSem = snapshot[.semesters].first { $0.title == "2026-2027学年 秋季学期" }
  #expect(newSem != nil)
  #expect(snapshot[.courses].first { $0.title == "大数据与人工智能" } != nil)
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
