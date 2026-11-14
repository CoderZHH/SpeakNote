import Foundation
import Observation

func thoughtTitle(_ content: String) -> String {
  let first = content.components(separatedBy: .newlines).first ?? ""
  return first.trimmingCharacters(in: .whitespaces).isEmpty ? "无标题" : first
}

func thoughtTags(_ item: WorkspaceItem) -> [String] {
  (try? JSONValue(json: item[.tags].string).array.map(\.string)) ?? []
}

/// One buffer and one serialized writer per thought, shared by every editor.
/// New empty editors never create a database row. Failed writes retain their input.
@MainActor @Observable final class ThoughtEditing {
  struct Buffer {
    var text: String
    var tags: [String]
    var expected: String
    var baseline: ThoughtContentVersion
    var persisted: Bool
    var day: String
    var createdAt: String
    var dirty = false
    var saving = false
    var error: String?
    var conflict: ThoughtContentVersion?
  }
  private(set) var buffers: [String: Buffer] = [:]
  @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  @ObservationIgnored var didSave: (@MainActor () -> Void)?

  /// Unsaved content remains reachable from the list even if its first write fails.
  var pendingItems: [WorkspaceItem] {
    buffers.compactMap { id, buffer in
      guard !buffer.persisted, !buffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      return WorkspaceItem(
        entity: .reflections,
        fields: [
          "id": .string(id), "content": .string(buffer.text),
          "tags": .string((try? JSONValue.array(buffer.tags.map(JSONValue.string)).json()) ?? "[]"),
          "day": .string(buffer.day), "created_at": .string(buffer.createdAt),
          "updated_at": .string(buffer.expected),
        ])
    }
  }
  func begin(_ item: WorkspaceItem) {
    guard buffers[item.id]?.dirty != true, buffers[item.id]?.saving != true else { return }
    buffers[item.id] = Buffer(
      text: item[.content].string, tags: thoughtTags(item),
      expected: item.fields.text("updated_at"),
      baseline: ThoughtContentVersion(fields: item.fields),
      persisted: true, day: item[.day].string, createdAt: item.createdAt)
  }
  func beginNew(id: String, tags: [String], now: Date = .now) {
    guard buffers[id] == nil else { return }
    buffers[id] = Buffer(
      text: "", tags: tags, expected: "", baseline: .init(text: "", tags: tags), persisted: false,
      day: Clock.day(now), createdAt: Clock.stamp(now))
  }
  func stage(id: String, text: String, store: WorkspaceStore) {
    guard buffers[id] != nil, buffers[id]?.text != text else { return }
    buffers[id]?.text = text
    enqueue(id: id, store: store)
  }
  func stageTags(id: String, tags: [String], store: WorkspaceStore) throws {
    let normalized = try Validation.tags(.array(tags.map(JSONValue.string))).array.map(\.string)
    guard buffers[id] != nil, buffers[id]?.tags != normalized else { return }
    buffers[id]?.tags = normalized
    enqueue(id: id, store: store)
  }
  private func enqueue(id: String, store: WorkspaceStore) {
    buffers[id]?.dirty = true
    jobs[id]?.cancel()
    jobs[id] = Task {
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      jobs[id] = nil
      await flush(id: id, store: store)
    }
  }
  func flush(id: String, store: WorkspaceStore) async {
    jobs[id]?.cancel()
    jobs[id] = nil
    if buffers[id]?.saving == true {
      await withCheckedContinuation { waiters[id, default: []].append($0) }
      return
    }
    guard buffers[id]?.dirty == true else { return }
    buffers[id]?.saving = true
    defer {
      buffers[id]?.saving = false
      let waiting = waiters.removeValue(forKey: id) ?? []
      waiting.forEach { $0.resume() }
    }
    while let buffer = buffers[id], buffer.dirty {
      guard !buffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        if buffer.persisted { buffers[id]?.error = "正文不能为空，原内容仍保留。" }
        return
      }
      do {
        let fields: [ItemField: JSONValue] = [
          .content: .string(buffer.text), .tags: .array(buffer.tags.map(JSONValue.string)),
        ]
        let result: CommandResult
        if buffer.persisted {
          result = try await store.perform(
            .update(
              .reflections, id: id, fields: fields,
              expectedThought: buffer.baseline))
        } else {
          result = try await store.perform(
            .create(
              .reflections, id: id,
              fields: fields.merging([.day: .string(buffer.day)]) { _, value in value }))
        }
        guard buffers[id] != nil else { return }
        buffers[id]?.persisted = true
        // SQLite normalizes the text. Use the exact version committed by the transaction.
        if let version = result.thoughtVersion { buffers[id]?.baseline = version }
        buffers[id]?.expected =
          store.snapshot.item(.reflections, id)?.fields.text("updated_at") ?? buffer.expected
        let changed = buffers[id]?.text != buffer.text || buffers[id]?.tags != buffer.tags
        buffers[id]?.dirty = changed
        buffers[id]?.error = nil
        buffers[id]?.conflict = nil
        didSave?()
      } catch {
        buffers[id]?.error = error.localizedDescription
        buffers[id]?.conflict = (error as? ThoughtSaveConflict)?.saved
        return
      }
    }
  }
  func resolve(id: String, reviewed: ThoughtContentVersion, keepDraft: Bool, store: WorkspaceStore)
    async
  {
    guard let draft = buffers[id], !draft.saving, draft.conflict == reviewed else { return }
    if keepDraft {
      // A later change still fails the same transactional version check.
      buffers[id]?.baseline = reviewed
      await flush(id: id, store: store)
      return
    }
    do {
      try await store.refresh()
      guard let active = buffers[id], !active.saving, active.conflict == reviewed,
        active.text == draft.text, active.tags == draft.tags
      else { return }
      guard let item = store.snapshot.item(.reflections, id) else {
        throw WorkBenchError("已保存的思考已删除，当前输入仍保留。")
      }
      let latest = ThoughtContentVersion(fields: item.fields)
      guard latest == reviewed else {
        buffers[id]?.conflict = latest
        return
      }
      remove(id)
      begin(item)
    } catch {
      buffers[id]?.error = error.localizedDescription
    }
  }
  func flushAll(store: WorkspaceStore) async {
    for id in Array(buffers.keys) { await flush(id: id, store: store) }
  }
  func remove(_ id: String) {
    jobs[id]?.cancel()
    jobs[id] = nil
    buffers[id] = nil
  }
}
