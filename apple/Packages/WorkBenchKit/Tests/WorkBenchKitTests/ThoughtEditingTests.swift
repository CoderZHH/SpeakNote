import Foundation
import Testing

@testable import WorkBenchKit

@Test @MainActor func newThoughtWaitsForContentAndSavesTagsWithoutDuplicates() async throws {
  let f = try Fixture()
  defer { f.clean() }
  let store = WorkspaceStore(
    database: try WorkspaceDatabase(url: f.directory.appendingPathComponent("main.sqlite")))
  try await store.refresh()
  let editing = ThoughtEditing()
  let id = UUID().uuidString
  editing.beginNew(id: id, tags: ["反思"], now: testNow)
  try editing.stageTags(id: id, tags: ["反思", "拍照"], store: store)
  await editing.flush(id: id, store: store)
  #expect(store.snapshot[.reflections].isEmpty && editing.pendingItems.isEmpty)
  editing.stage(id: id, text: "拍摄之后的反思\n长一点的正文", store: store)
  await editing.flush(id: id, store: store)
  await editing.flush(id: id, store: store)
  #expect(store.snapshot[.reflections].count == 1)
  #expect(thoughtTags(store.snapshot.item(.reflections, id)!) == ["反思", "拍照"])
  #expect(store.snapshot.item(.reflections, id)?[.day].string == Clock.day(testNow))
  #expect(editing.pendingItems.isEmpty && editing.buffers[id]?.dirty == false)
  try editing.stageTags(id: id, tags: ["拍照", "拍照"], store: store)
  await editing.flush(id: id, store: store)
  let reloaded = try await store.database.snapshot()
  #expect(thoughtTags(reloaded.item(.reflections, id)!) == ["拍照"])
  #expect(reloaded.item(.reflections, id)?[.content].string == "拍摄之后的反思\n长一点的正文")
}

@Test @MainActor func thoughtContentAndTagsSerializeEditsDuringSaveAndFlushAllWaits() async throws {
  let f = try Fixture()
  defer { f.clean() }
  let store = WorkspaceStore(
    database: try WorkspaceDatabase(url: f.directory.appendingPathComponent("main.sqlite")))
  let id = try await store.perform(.create(.reflections, fields: [.content: .string("原内容")])).id!
  let editing = ThoughtEditing()
  editing.begin(store.snapshot.item(.reflections, id)!)
  var gate: CheckedContinuation<Void, Never>?
  var held = false
  store.didRefresh = {
    if !held {
      held = true
      await withCheckedContinuation { gate = $0 }
    }
  }
  editing.stage(id: id, text: "第一版", store: store)
  let save = Task { await editing.flush(id: id, store: store) }
  for _ in 0..<1000 {
    if gate != nil { break }
    await Task.yield()
  }
  #expect(gate != nil)
  editing.stage(id: id, text: "最终版", store: store)
  try editing.stageTags(id: id, tags: ["认知", "自定义"], store: store)
  var completed = false
  let leave = Task {
    await editing.flushAll(store: store)
    completed = true
  }
  for _ in 0..<5 { await Task.yield() }
  #expect(!completed)
  gate?.resume()
  await save.value
  await leave.value
  #expect(completed && editing.buffers[id]?.dirty == false)
  #expect(store.snapshot.item(.reflections, id)?[.content].string == "最终版")
  #expect(thoughtTags(store.snapshot.item(.reflections, id)!) == ["认知", "自定义"])
}

@Test @MainActor func thoughtConflictRetainsBothTextAndTagsAndDoesNotOverwriteRemote() async throws
{
  let f = try Fixture()
  defer { f.clean() }
  let store = WorkspaceStore(
    database: try WorkspaceDatabase(url: f.directory.appendingPathComponent("main.sqlite")))
  let id = try await store.perform(.create(.reflections, fields: [.content: .string("原内容")])).id!
  let editing = ThoughtEditing()
  editing.begin(store.snapshot.item(.reflections, id)!)
  editing.stage(id: id, text: "本机输入", store: store)
  try editing.stageTags(id: id, tags: ["反思"], store: store)
  _ = try await store.perform(.update(.reflections, id: id, fields: [.content: .string("另一份修改")]))
  await editing.flush(id: id, store: store)
  #expect(editing.buffers[id]?.dirty == true && editing.buffers[id]?.error != nil)
  #expect(editing.buffers[id]?.text == "本机输入" && editing.buffers[id]?.tags == ["反思"])
  editing.begin(store.snapshot.item(.reflections, id)!)
  #expect(editing.buffers[id]?.text == "本机输入")
  #expect(store.snapshot.item(.reflections, id)?[.content].string == "另一份修改")
  #expect(thoughtTags(store.snapshot.item(.reflections, id)!).isEmpty)

  let firstReview = try #require(editing.buffers[id]?.conflict)
  _ = try await store.perform(.update(.reflections, id: id, fields: [.content: .string("后来又修改")]))
  await editing.resolve(id: id, reviewed: firstReview, keepDraft: true, store: store)
  #expect(editing.buffers[id]?.text == "本机输入")
  #expect(editing.buffers[id]?.conflict?.text == "后来又修改")
  #expect(store.snapshot.item(.reflections, id)?[.content].string == "后来又修改")
  let secondReview = try #require(editing.buffers[id]?.conflict)
  await editing.resolve(id: id, reviewed: secondReview, keepDraft: true, store: store)
  #expect(editing.buffers[id]?.error == nil)
  #expect(store.snapshot.item(.reflections, id)?[.content].string == "本机输入")
  #expect(thoughtTags(store.snapshot.item(.reflections, id)!) == ["反思"])

  editing.stage(id: id, text: "第二次本机输入", store: store)
  _ = try await store.perform(.update(.reflections, id: id, fields: [.content: .string("选用这份")]))
  await editing.flush(id: id, store: store)
  let latest = try #require(editing.buffers[id]?.conflict)
  await editing.resolve(id: id, reviewed: latest, keepDraft: false, store: store)
  #expect(editing.buffers[id]?.text == "选用这份")
  #expect(editing.buffers[id]?.dirty == false && editing.buffers[id]?.error == nil)
}

@Test @MainActor func thoughtAutosaveAfterTrailingNewlineUsesCommittedVersion() async throws {
  let f = try Fixture()
  defer { f.clean() }
  let store = WorkspaceStore(database: try WorkspaceDatabase(url: f.directory.appendingPathComponent("main.sqlite")))
  let editing = ThoughtEditing()
  let id = UUID().uuidString
  editing.beginNew(id: id, tags: [])
  for text in ["标题\n", "标题\n正文一\n ", "标题\n正文一\n正文二"] {
    editing.stage(id: id, text: text, store: store)
    await editing.flush(id: id, store: store)
    #expect(editing.buffers[id]?.error == nil)
    #expect(editing.buffers[id]?.text == text, "自动保存不能移走编辑中的换行")
    #expect(store.snapshot.item(.reflections, id)?[.content].string
      == text.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

@Test @MainActor func thoughtRejectsInvalidTagsAndEmptyOverwrite() async throws {
  let f = try Fixture()
  defer { f.clean() }
  let store = WorkspaceStore(
    database: try WorkspaceDatabase(url: f.directory.appendingPathComponent("main.sqlite")))
  let id = try await store.perform(.create(.reflections, fields: [.content: .string("保留正文")])).id!
  let editing = ThoughtEditing()
  editing.begin(store.snapshot.item(.reflections, id)!)
  #expect(throws: (any Error).self) {
    try editing.stageTags(id: id, tags: ["a,b"], store: store)
  }
  #expect(throws: (any Error).self) {
    try editing.stageTags(id: id, tags: (0..<9).map(String.init), store: store)
  }
  editing.stage(id: id, text: " \n", store: store)
  await editing.flush(id: id, store: store)
  #expect(store.snapshot.item(.reflections, id)?[.content].string == "保留正文")
  #expect(editing.buffers[id]?.error != nil && editing.buffers[id]?.dirty == true)
}

@Test func thoughtListTitleUsesLiteralFirstLine() {
  #expect(thoughtTitle("第一行标题\n正文") == "第一行标题")
  #expect(thoughtTitle("标题\r\n下一行") == "标题")
  #expect(thoughtTitle("\n只写正文") == "无标题")
  #expect(thoughtTitle("") == "无标题")
}
#if os(macOS)
  import AppKit
  import SwiftUI
  @Test @MainActor func nativeThoughtFormattingPreservesContentAndCaret() {
    var content = "第一行是标题\n正文保留 emoji 🃏 和换行\n第三行"
    let original = content
    let editor = ThoughtTextEditor(
      text: Binding(get: { content }, set: { content = $0 }), focused: .constant(false))
    let coordinator = ThoughtTextEditor.Coordinator(editor)
    let view = NSTextView()
    view.string = content
    let caret = NSRange(location: (content as NSString).length, length: 0)
    view.setSelectedRange(caret)
    coordinator.style(view)
    #expect(view.string == original && content == original)
    #expect(view.selectedRange() == caret)
    let heading = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    let bodyOffset = (content as NSString).range(of: "正文").location
    let body = view.textStorage?.attribute(.font, at: bodyOffset, effectiveRange: nil) as? NSFont
    #expect((heading?.pointSize ?? 0) > (body?.pointSize ?? 0))
    #expect(view.typingAttributes[.font] as? NSFont == body)
    view.setSelectedRange(NSRange(location: 0, length: 0))
    coordinator.typing(view)
    #expect(view.typingAttributes[.font] as? NSFont == heading)
  }
#endif

@Test @MainActor func thoughtAutosaveAcceptsMetadataRefreshButProtectsRealContent() async throws {
  let f = try Fixture()
  defer { f.clean() }
  let store = WorkspaceStore(database: try WorkspaceDatabase(url: f.directory.appendingPathComponent("main.sqlite")))
  let id = try await store.perform(.create(.reflections, fields: [.content: .string("标题\n正文")])).id!
  let editing = ThoughtEditing()
  editing.begin(store.snapshot.item(.reflections, id)!)
  editing.stage(id: id, text: "标题\n持续输入第一段", store: store)
  // A sync echo or an unrelated field refresh advances the row timestamp,
  // without changing either of the editor's protected fields.
  _ = try await store.perform(.update(.reflections, id: id, fields: [.day: .string(Clock.day())]))
  await editing.flush(id: id, store: store)
  #expect(editing.buffers[id]?.error == nil)
  for n in 0..<20 {
    editing.stage(id: id, text: "标题\n持续输入第\(n)段 🃏", store: store)
    await editing.flush(id: id, store: store)
    #expect(editing.buffers[id]?.error == nil)
  }
  #expect(try await store.database.snapshot().item(.reflections, id)?[.content].string == "标题\n持续输入第19段 🃏")
  editing.stage(id: id, text: "不能覆盖其他地方的内容", store: store)
  _ = try await store.perform(.update(.reflections, id: id, fields: [.content: .string("另一台设备的修改")]))
  await editing.flush(id: id, store: store)
  #expect(editing.buffers[id]?.error != nil)
  #expect(editing.buffers[id]?.text == "不能覆盖其他地方的内容")
  #expect(store.snapshot.item(.reflections, id)?[.content].string == "另一台设备的修改")
}
