#if os(macOS)
import Foundation
import Testing

@testable import WorkBenchKit

@Test func assistantCredentialsStayInsideTheirWorkspace() throws {
  let first = try Fixture()
  let second = try Fixture()
  defer { first.clean(); second.clean() }
  let local = AssistantLocal(workspaceDirectory: first.directory)
  let isolated = AssistantLocal(workspaceDirectory: second.directory)
  try local.prepare()
  try isolated.prepare()
  #expect(local.directory.deletingLastPathComponent().path == first.directory.path)
  #expect(local.directory != isolated.directory)
  let originalKey = try local.key()
  #expect(originalKey != nil)
  #expect(try isolated.key() != originalKey)
  try local.prepare()
  #expect(try local.key() == originalKey)
  let permissions = try FileManager.default.attributesOfItem(atPath: local.directory.path)
  #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test @MainActor func assistantAppliesOneMessageAcrossTheLocalBridgeOnlyOnce() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let local = AssistantLocal(directory: URL(fileURLWithPath: "/private/tmp/wb-" + UUID().uuidString))
  try local.prepare()
  defer { try? FileManager.default.removeItem(at: local.directory) }
  let initialKey = try local.key()
  try local.prepare()
  let reusedKey = try local.key() == initialKey
  #expect(reusedKey)
  let database = try WorkspaceDatabase(url: fixture.directory.appendingPathComponent("workbench.sqlite"))
  let store = WorkspaceStore(database: database)
  let session = AppSession(role: .workbench)
  let bridge = try #require(AssistantBridge(local) { operation, arguments in
    await session.handleAssistant(operation, arguments, store: store)
  })
  defer { withExtendedLifetime(bridge) {} }
  let agent = Agent(workspace: { try await local.request($0, $1) }, completion: { _ in
    .object(["role": .string("assistant"), "tool_calls": .array([
      .object(["id": .string("call_1"), "function": .object([
        "name": .string(AssistantContract.applyTool),
        "arguments": .string("""
          {"changes":[
            {"kind":"create","entity":"projects","ref":"parent","fields":{"title":"新项目"}},
            {"kind":"create","entity":"tasks","ref":"item","attach_image":true,"fields":{"title":"交报告","project_id":"@parent","importance":3}},
            {"kind":"start_focus","entity":"tasks","target_id":"@item"}
          ]}
          """),
      ])]),
    ])])
  })
  let image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
  let imageOnly = try await agent.respond(to: "", image: image, history: [], pending: nil,
    requestID: "wechat-" + String(repeating: "0", count: 64))
  #expect(imageOnly.text.contains("请用文字"))
  #expect(try await database.snapshot()[.tasks].isEmpty)
  let id = "wechat-" + String(repeating: "1", count: 64)
  let reply = try await agent.respond(to: "新建项目和任务，附上图片并开始专注", image: image,
    history: [], pending: nil, requestID: id)
  #expect(reply.pending == nil)
  #expect(reply.text.contains("已附图片"))
  #expect(!reply.text.contains("待确认"))
  let replay = try await agent.respond(to: "新建项目和任务，附上图片并开始专注", image: image,
    history: [], pending: nil, requestID: id)
  #expect(replay.text == reply.text)
  let data = try await database.snapshot()
  let task = try #require(data[.tasks].first)
  #expect(reply.createdTaskID == task.id)
  #expect(replay.createdTaskID == task.id)
  let project = try #require(data[.projects].first)
  #expect(data[.tasks].count == 1 && data[.projects].count == 1)
  #expect(task[.projectID] == .string(project.id))
  #expect(data[.attachments].count == 1 && data[.attachments].first?[.taskID] == .string(task.id))
  #expect(data[.focusSessions].count == 1 && data[.focusSessions].first?[.taskID] == .string(task.id))
  #expect(store.snapshot[.tasks].map(\.id) == data[.tasks].map(\.id))
  #expect(try await database.pendingDocuments().contains { $0.id == task.id })
}

@Test func assistantIgnoresOtherSendersAndReplayedMessages() {
  let owner = WeChatCredentials(base: WeChatClient.defaultBase, token: "dummy", bot: "bot", owner: "me")
  let state = AssistantState(handled: ["already-handled"])
  let message: JSONValue = .object([
    "message_type": .integer(1), "from_user_id": .string("me"),
    "message_id": .integer(42), "context_token": .string("conversation"),
  ])
  #expect(AssistantCommand.incomingID(message, owner, state) == "42")
  for (key, value): (String, JSONValue) in [
    ("from_user_id", .string("somebody-else")), ("message_type", .integer(2)),
    ("group_id", .string("group")), ("message_id", .string("already-handled")),
    ("context_token", .null),
  ] {
    var rejected = message
    rejected[key] = value
    #expect(AssistantCommand.incomingID(rejected, owner, state) == nil)
  }
}
#endif
#if os(macOS)
@Test func assistantImageContextExpiresAndOldStateStillLoads() throws {
  let oldState = try JSONDecoder().decode(AssistantState.self, from: Data(#"{"cursor":"","history":[],"handled":[]}"#.utf8))
  #expect(oldState.instructionForIncomingImage() == nil)
  var state = AssistantState(recentUserAt: testNow, recentUserInstruction: "记随手记并附图")
  #expect(state.instructionForIncomingImage(now: testNow) == nil)
  state.waitingForImage = true
  #expect(state.instructionForIncomingImage(now: testNow.addingTimeInterval(10)) != nil)
  #expect(state.instructionForIncomingImage(now: testNow.addingTimeInterval(121)) == nil)
}

@Test func assistantReadsWeChatVoiceTextAndRejectsMissingTranscripts() throws {
  let voice: JSONValue = .object([
    "type": .integer(3), "voice_item": .object(["text": .string("  寄顺丰快递  ")]),
  ])
  #expect(try AssistantCommand.messageText([voice]) == "寄顺丰快递")
  let caption: JSONValue = .object([
    "type": .integer(1), "text_item": .object(["text": .string("帮我加条任务")]),
  ])
  #expect(try AssistantCommand.messageText([caption, voice]) == "帮我加条任务\n寄顺丰快递")
  for transcript: JSONValue in [.null, .string("  \n"), .integer(7)] {
    var missing = voice
    missing["voice_item"]["text"] = transcript
    #expect(throws: WorkBenchError.self) {
      try AssistantCommand.messageText([caption, missing])
    }
  }
}

@Test func assistantBoundsModelWaitAndDoesNotExecuteAfterTimeout() async throws {
  let agent = Agent(workspace: { operation, _ in
    #expect(operation != "apply")
    return .object(["result": .null])
  }, completion: { _ in
    try await Task.sleep(for: .seconds(5))
    return .object(["role": .string("assistant"), "content": .string("late")])
  }, responseTimeout: .milliseconds(30))
  do {
    _ = try await agent.respond(to: "寄快递", image: nil, history: [], pending: nil,
      requestID: "wechat-" + String(repeating: "e", count: 64))
    Issue.record("Expected the model response deadline to expire")
  } catch let error as WorkBenchError {
    #expect(error.message.contains("DeepSeek 响应超时"))
    #expect(error.message.contains("尚未执行"))
  }
}
#endif
#if os(macOS)
@Test func assistantBatchesFragmentsAndImagesAndPersistsTheSameRequest() throws {
  let packet: JSONValue = .object([
    "item_list": .array([.object(["type": .integer(1), "text_item": .object(["text": .string("帮我创建任务")])])]),
    "context_token": .string("first"),
  ])
  var batch = ConversationBatch(.init(id: "1", packet: packet), now: testNow)
  #expect(batch.waitInterval(now: testNow.addingTimeInterval(1)) == 1)
  var continuation = packet
  continuation["item_list"] = .array([.object(["type": .integer(1),
    "text_item": .object(["text": .string("拍摄视频，把接下来的图存为附件")])])])
  continuation["context_token"] = .string("second")
  batch.append(.init(id: "2", packet: continuation), now: testNow.addingTimeInterval(1))
  #expect(batch.waitInterval(now: testNow.addingTimeInterval(2)) == 1)
  var picture = packet
  picture["item_list"] = .array([.object(["type": .integer(2), "image_item": .object([:])])])
  picture["context_token"] = .string("last")
  batch.append(.init(id: "3", packet: picture), now: testNow.addingTimeInterval(2))
  batch.append(.init(id: "3", packet: picture), now: testNow.addingTimeInterval(3))
  #expect(batch.messages.count == 3)
  #expect(batch.waitInterval(now: testNow.addingTimeInterval(4)) == 0)
  #expect(try AssistantCommand.messageText(batch.items) == "帮我创建任务\n拍摄视频，把接下来的图存为附件")
  #expect(batch.items.filter { $0["type"] == .integer(2) }.count == 1)
  #expect(batch.latestPacket["context_token"] == .string("last"))
  let state = AssistantState(inFlight: batch)
  let restored = try JSONDecoder().decode(AssistantState.self, from: JSONEncoder().encode(state))
  #expect(restored.inFlight?.requestID(bot: "me") == batch.requestID(bot: "me"))
  #expect(restored.inFlight?.messages.map(\.id) == ["1", "2", "3"])
  batch.append(.init(id: "4", packet: continuation), now: testNow.addingTimeInterval(9.5))
  #expect(batch.waitInterval(now: testNow.addingTimeInterval(10)) == 0)
}

@Test @MainActor func assistantUsesCurrentTaskIdentityAndIgnoresDeletedOrExpiredContext() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let database = try WorkspaceDatabase(url: fixture.directory.appendingPathComponent("workbench.sqlite"))
  let old = try await database.applyAssistantChanges(.array([.object([
    "kind": .string("create"), "entity": .string("tasks"),
    "fields": .object(["title": .string("寄快递")]),
  ])]), requestID: "old", attachments: [])
  let oldID = try #require(old["items"].array.first?["id"].string)
  let row = try await database.assistantSearch(.object(["entity": .string("tasks"), "query": .string("寄快递")]))
  _ = try await database.applyAssistantChanges(.array([.object([
    "kind": .string("delete"), "entity": .string("tasks"),
    "target_id": .string(oldID), "expected_version": row["items"].array[0]["version"],
  ])]), requestID: "deleted", attachments: [])
  let created = try await database.applyAssistantChanges(.array([.object([
    "kind": .string("create"), "entity": .string("tasks"),
    "fields": .object(["title": .string("拍摄视频")]),
  ])]), requestID: "new", attachments: [])
  let id = try #require(created["items"].array.first?["id"].string)
  let agent = Agent(workspace: { operation, arguments in
    switch operation {
    case "recent": return .object(["result": try await database.assistantRecentContext()])
    case "search": return .object(["result": try await database.assistantSearch(arguments)])
    default: return .object(["result": .null])
    }
  }, completion: { messages in
    let context = try messages[0]["content"].string
    #expect(context.contains(id))
    #expect(context.contains("拍摄视频"))
    #expect(!context.contains(oldID))
    #expect(!context.contains("寄快递"))
    #expect(!messages.contains { $0["content"] == .string("过期话题") })
    return .object(["role": .string("assistant"), "content": .string("使用最新任务")])
  })
  _ = try await agent.respond(to: "把图片加到这个任务", image: nil,
    history: [.init(user: "过期话题", assistant: "以前的回复", createdAt: .now.addingTimeInterval(-1801))],
    pending: nil, requestID: "context-test")
}
#endif
#if os(macOS)
@Test func assistantOnlyWaitsForImagesAfterAnExplicitAttachmentRequest() async throws {
  let agent = Agent(workspace: { operation, _ in
    #expect(operation != "apply")
    return .object(["result": .null])
  }, completion: { _ in
    .object(["role": .string("assistant"), "tool_calls": .array([.object([
      "id": .string("attach"),
      "function": .object(["name": .string(AssistantContract.applyTool),
        "arguments": .string(#"{"changes":[{"kind":"create","entity":"tasks","attach_image":true,"fields":{"title":"拍摄视频"}}]}"#)]),
    ])])])
  })
  let reply = try await agent.respond(to: "创建拍摄视频任务，我接着发图作为附件", image: nil,
    history: [], pending: nil, requestID: "await-picture")
  #expect(reply.waitingForImage)
  #expect(reply.text.contains("图片发来"))
  let legacy = try JSONDecoder().decode(ChatTurn.self,
    from: Data(#"{"user":"旧话题","assistant":"旧回复"}"#.utf8))
  #expect(!legacy.isRecent())
}
#endif
