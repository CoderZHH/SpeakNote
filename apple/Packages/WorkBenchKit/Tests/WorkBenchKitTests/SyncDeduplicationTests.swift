import Foundation
import Testing

@testable import WorkBenchKit

private struct ConflictedWorkspacePair {
  let a = try! Fixture(), b = try! Fixture()
  let source: WorkspaceEngine, target: WorkspaceEngine
  let id: String
  init() throws {
    source = try a.workspace(); target = try b.workspace()
    id = try source.perform(.create(.tasks, fields: [.title: .string("原名称")]), now: testNow).id!
    let seed = try source.pendingDocuments()
    try target.receive(seed)
    for doc in seed { try source.acknowledge(doc, serverFields: "seed") }
    _ = try source.perform(.update(.tasks, id: id,
      fields: [.title: .string("共享名称"), .notes: .string("共享端独立添加的备注")]), now: testNow.addingTimeInterval(10))
    _ = try target.perform(.update(.tasks, id: id, fields: [.title: .string("本机名称")]), now: testNow.addingTimeInterval(20))
    try target.receive(source.pendingDocuments())
  }
  func clean() { a.clean(); b.clean() }
}

@Test func concurrentCompletionDatesMergeWithoutDuplicateTasksOrConflicts() throws {
  let a = try Fixture(), b = try Fixture()
  defer { a.clean(); b.clean() }
  let source = try a.workspace(), target = try b.workspace()
  let id = try source.perform(.create(.tasks, fields: [.title: .string("附件加不上")]), now: testNow).id!
  let seed = try source.pendingDocuments()
  try target.receive(seed)
  for doc in seed { try source.acknowledge(doc, serverFields: "seed") }
  _ = try source.perform(.update(.tasks, id: id, fields: [.status: .string("done")]), now: testNow.addingTimeInterval(10))
  _ = try target.perform(.update(.tasks, id: id, fields: [.status: .string("done")]), now: testNow.addingTimeInterval(20))
  let left = try source.pendingDocuments(), right = try target.pendingDocuments()
  try source.receive(right); try target.receive(left)
  for engine in [source, target] {
    let snapshot = try engine.snapshot()
    #expect(snapshot[.tasks].count == 1)
    #expect(snapshot.conflicts.isEmpty)
    #expect(try engine.db.record("tasks", id: id)["completed_at"] == .string(Clock.stamp(testNow.addingTimeInterval(10))))
  }
  #expect(try source.db.record("tasks", id: id) == target.db.record("tasks", id: id))
}

@Test func sameStatusMergePreservesIndependentTextEditsAndGenuineStatusConflict() throws {
  let base: JSONValue = .object(["id": .string("same"), "title": .string("原名称"),
    "notes": .string(""), "status": .string("todo"), "completed_at": .null, "abandoned_at": .null])
  var local = base, remote = base
  local["status"] = .string("done"); local["completed_at"] = .string(Clock.stamp(testNow))
  local["title"] = .string("本机名称")
  remote["status"] = .string("done"); remote["completed_at"] = .string(Clock.stamp(testNow.addingTimeInterval(10)))
  remote["notes"] = .string("共享备注")
  let merged = RecordMerge.workspace(base: base, local: local, remote: remote)
  #expect(!merged.1)
  #expect(merged.0["title"] == local["title"] && merged.0["notes"] == remote["notes"])
  remote["status"] = .string("abandoned"); remote["completed_at"] = .null
  remote["abandoned_at"] = .string(Clock.stamp(testNow.addingTimeInterval(10)))
  #expect(RecordMerge.workspace(base: base, local: local, remote: remote).1)
}

@Test func repeatedIncomingConflictRetainsOneSavedVersionAndStableReviewRevision() throws {
  let pair = try ConflictedWorkspacePair()
  defer { pair.clean() }
  let original = try #require(pair.target.snapshot().conflicts.first)
  try pair.target.receive(pair.source.pendingDocuments())
  let replay = try #require(pair.target.snapshot().conflicts.first)
  #expect(original.id == replay.id && original.revision == replay.revision)
  _ = try pair.target.perform(.update(.tasks, id: pair.id, fields: [.title: .string("本机名称")]), now: testNow.addingTimeInterval(30))
  try pair.target.receive(pair.source.pendingDocuments())
  #expect(try pair.target.snapshot().conflicts.count == 1)
  #expect(try pair.target.snapshot().conflicts[0].id == original.id)
}

@Test func savedVersionReplacesSameIdentityAndPreservesIndependentRemoteChanges() throws {
  let pair = try ConflictedWorkspacePair()
  defer { pair.clean() }
  let conflict = try #require(pair.target.snapshot().conflicts.first)
  #expect(!conflict.base.isNull && conflict.remote["title"] == .string("共享名称"))
  _ = try pair.target.perform(.resolveConflict(id: conflict.id, choice: .saved, expectedRevision: conflict.revision), now: testNow)
  let rows = try pair.target.snapshot()[.tasks]
  #expect(rows.count == 1 && rows[0].id == pair.id && rows[0].title == "本机名称")
  #expect(rows[0][.notes] == .string("共享端独立添加的备注"))
  #expect(try pair.target.snapshot().conflicts.isEmpty)
  #expect(try pair.target.pendingDocuments().contains { $0.id == pair.id && $0.payload["title"] == .string("本机名称") })
  _ = try pair.target.perform(.resolveConflict(id: conflict.id, choice: .saved, expectedRevision: conflict.revision), now: testNow)
  #expect(try pair.target.snapshot()[.tasks].count == 1)
}

@Test func keepingBothIsExplicitStableAndRetryDoesNotCreateAnotherCopy() throws {
  let pair = try ConflictedWorkspacePair()
  defer { pair.clean() }
  let conflict = try #require(pair.target.snapshot().conflicts.first)
  for _ in 0..<3 {
    _ = try pair.target.perform(.restoreConflict(id: conflict.id), now: testNow)
  }
  let rows = try pair.target.snapshot()[.tasks]
  #expect(rows.count == 2 && Set(rows.map(\.id)) == Set([pair.id, conflict.id]))
  #expect(try pair.target.snapshot().conflicts.isEmpty)
}

@Test func staleWorkspaceReviewPreservesNewerEditsAndRemainsActionable() throws {
  let pair = try ConflictedWorkspacePair()
  defer { pair.clean() }
  let conflict = try #require(pair.target.snapshot().conflicts.first)
  _ = try pair.target.perform(.update(.tasks, id: pair.id, fields: [.notes: .string("核对期间的新输入")]), now: testNow.addingTimeInterval(40))
  #expect(throws: WorkBenchError.self) {
    try pair.target.perform(.resolveConflict(id: conflict.id, choice: .saved, expectedRevision: conflict.revision), now: testNow)
  }
  #expect(try pair.target.db.record("tasks", id: pair.id).text("notes") == "核对期间的新输入")
  let refreshed = try #require(pair.target.snapshot().conflicts.first)
  _ = try pair.target.perform(.resolveConflict(id: refreshed.id, choice: .current, expectedRevision: refreshed.revision), now: testNow)
  #expect(try pair.target.snapshot().conflicts.isEmpty)
}

@Test func startupRemovesLegacyRedundantCopiesWithoutMergingDifferentRecordIDs() throws {
  let pair = try ConflictedWorkspacePair()
  defer { pair.clean() }
  let conflict = try #require(pair.target.snapshot().conflicts.first)
  var repeated = conflict.local
  repeated["updated_at"] = .string(Clock.stamp(testNow.addingTimeInterval(80)))
  try pair.target.db.insert("wb_sync_conflicts", ["id": .id(), "entity": .string("tasks"),
    "record_id": .string(pair.id), "payload": .string(try repeated.json()), "created_at": .string(Clock.stamp(testNow))])
  let secondID = try pair.target.perform(.create(.tasks, fields: [.title: .string("共享名称")]), now: testNow).id!
  let identical = try pair.target.db.record("tasks", id: secondID)
  try pair.target.db.insert("wb_sync_conflicts", ["id": .id(), "entity": .string("tasks"),
    "record_id": .string(secondID), "payload": .string(try JSONValue.object(identical).json()), "created_at": .string(Clock.stamp(testNow))])
  let reopened = try pair.b.workspace()
  #expect(try reopened.snapshot()[.tasks].count == 2)
  #expect(try reopened.snapshot().conflicts.count == 1)
  #expect(try reopened.snapshot().conflicts[0].local["title"] == .string("本机名称"))
}

private func workflow(_ stage: PhotoStage, at date: Date) -> JSONValue {
  let rank = PhotoStage.allCases.firstIndex(of: stage)!
  var value: JSONValue = .object(["id": .string("same-order"), "stage": .string(stage == .completed ? "refund" : stage.rawValue),
    "updated_at": .string(Clock.stamp(date)), "updated_by": .string("device"),
    "completed_at": stage == .completed ? .string(Clock.stamp(date)) : .null])
  for (i, key) in ["output_at", "review_at", "return_at", "submit_at"].enumerated() {
    value[key] = rank > i ? .string(Clock.stamp(date)) : .null
  }
  return value
}

@Test func workflowForwardProgressAndRepeatedStageMergeButRollbackStaysExplicit() {
  let base = workflow(.output, at: testNow)
  let local = workflow(.review, at: testNow.addingTimeInterval(10))
  let remote = workflow(.submit, at: testNow.addingTimeInterval(20))
  let merged = RecordMerge.photo(kind: "workflow", base: base, local: local, remote: remote)
  #expect(merged?["stage"] == .string("submit"))
  #expect(merged?["output_at"] == local["output_at"])
  #expect(RecordMerge.photo(kind: "workflow", base: base, local: remote, remote: local) == merged)
  #expect(RecordMerge.photo(kind: "workflow", base: workflow(.return, at: testNow), local: local, remote: remote) == nil)
  #expect(RecordMerge.photo(kind: "workflow", base: .null, local: local, remote: remote) == nil)
  let same = RecordMerge.photo(kind: "workflow", base: .null,
    local: workflow(.completed, at: testNow), remote: workflow(.completed, at: testNow.addingTimeInterval(10)))
  #expect(same?["completed_at"] == .string(Clock.stamp(testNow)))
}

@Test func persistedWorkflowConflictIsAutomaticallyReconciledOnUpgrade() throws {
  let a = try Fixture(), b = try Fixture()
  defer { a.clean(); b.clean() }
  let source = try a.photos(), target = try b.photos()
  try source.bind(a.space); try target.bind(a.space)
  var input = PhotoOrderInput(); input.brand = "原共享订单"
  _ = try source.perform(.create(input), now: testNow)
  let seed = try source.pendingDocuments(); try target.receive(seed)
  for doc in seed { try source.acknowledge(doc, serverFields: "seed") }
  _ = try source.perform(.transition(id: input.id, stage: .submit,
    expectedRevision: source.snapshot().orders[0].workflowRevision), now: testNow.addingTimeInterval(20))
  _ = try target.perform(.transition(id: input.id, stage: .review,
    expectedRevision: target.snapshot().orders[0].workflowRevision), now: testNow.addingTimeInterval(10))
  let incoming = try #require(source.pendingDocuments().first { $0.kind == "workflow" })
  try target.db.execute("UPDATE photo_records SET conflict=? WHERE id=?",
    [.string(try incoming.value().json()), .string(incoming.id)])
  let reopened = try b.photos()
  #expect(try reopened.snapshot().conflicts.isEmpty)
  #expect(try reopened.snapshot().orders[0].stage == .submit)
  #expect(try reopened.snapshot().orders.count == 1)
  try reopened.receive(source.pendingDocuments())
  #expect(try reopened.snapshot().conflicts.isEmpty)
}

@Test func workflowConcurrentChangesConvergeWithoutGrowingRecords() throws {
  let a = try Fixture(), b = try Fixture()
  defer { a.clean(); b.clean() }
  let left = try a.photos(), right = try b.photos()
  try left.bind(a.space); try right.bind(a.space)
  var input = PhotoOrderInput(); input.brand = "并发推进"
  _ = try left.perform(.create(input), now: testNow)
  let seed = try left.pendingDocuments(); try right.receive(seed)
  for doc in seed { try left.acknowledge(doc, serverFields: "seed") }
  _ = try left.perform(.transition(id: input.id, stage: .review,
    expectedRevision: left.snapshot().orders[0].workflowRevision), now: testNow.addingTimeInterval(10))
  _ = try right.perform(.transition(id: input.id, stage: .return,
    expectedRevision: right.snapshot().orders[0].workflowRevision), now: testNow.addingTimeInterval(20))
  let l = try left.pendingDocuments(), r = try right.pendingDocuments()
  try left.receive(r); try right.receive(l)
  for _ in 0..<3 {
    try left.receive(right.pendingDocuments()); try right.receive(left.pendingDocuments())
  }
  #expect(try left.payload(left.row("workflow:" + input.id)) == right.payload(right.row("workflow:" + input.id)))
  #expect(try left.snapshot().conflicts.isEmpty && right.snapshot().conflicts.isEmpty)
  #expect(try left.snapshot().orders[0].stage == .return && right.snapshot().orders.count == 1)
  #expect(try left.db.rows("SELECT id FROM photo_records").count == right.db.rows("SELECT id FROM photo_records").count)
}

@Test func repeatedSaveAndStageConfirmationDoNotCreateChangesOrActivity() throws {
  let f = try Fixture()
  defer { f.clean() }
  let workspace = try f.workspace()
  let id = try workspace.perform(.create(.tasks, fields: [.title: .string("原任务")]), now: testNow).id!
  let pending = try #require(workspace.pendingDocuments().first)
  try workspace.acknowledge(pending, serverFields: "seed")
  _ = try workspace.perform(.update(.tasks, id: id, fields: [.title: .string("原任务")]), now: testNow.addingTimeInterval(20))
  #expect(try workspace.pendingDocuments().isEmpty)
  let photos = try f.photos(); try photos.bind(f.space)
  var input = PhotoOrderInput(); input.brand = "重复确认"
  _ = try photos.perform(.create(input), now: testNow)
  let before = try photos.db.rows("SELECT * FROM photo_records")
  for _ in 0..<3 {
    _ = try photos.perform(.transition(id: input.id, stage: .output,
      expectedRevision: 0), now: testNow.addingTimeInterval(30))
  }
  #expect(try photos.db.rows("SELECT * FROM photo_records") == before)
}

@Test func legacyCompletionOnlyCopyIsRemovedAndRestoreDoesNotDuplicateIt() throws {
  let f = try Fixture()
  defer { f.clean() }
  let engine = try f.workspace()
  let id = try engine.perform(.create(.tasks, fields: [.title: .string("已完成任务"), .status: .string("done")]), now: testNow).id!
  var saved = try engine.db.record("tasks", id: id)
  saved["completed_at"] = .string(Clock.stamp(testNow.addingTimeInterval(20)))
  saved["updated_at"] = saved["completed_at"]
  let archiveID = UUID().uuidString.lowercased()
  try engine.db.insert("wb_sync_conflicts", ["id": .string(archiveID), "entity": .string("tasks"),
    "record_id": .string(id), "payload": .string(try JSONValue.object(saved).json()), "created_at": .string(Clock.stamp())])
  _ = try engine.perform(.restoreConflict(id: archiveID), now: testNow)
  #expect(try engine.snapshot()[.tasks].count == 1)
  #expect(try engine.snapshot().conflicts.isEmpty)
  #expect(try f.workspace().snapshot()[.tasks][0].id == id)
}

@Test func unresolvedPhotoRollbackSurvivesOldBaselineReplayAndResolutionRetry() throws {
  let a = try Fixture(), b = try Fixture()
  defer { a.clean(); b.clean() }
  let source = try a.photos(), target = try b.photos()
  try source.bind(a.space); try target.bind(a.space)
  var input = PhotoOrderInput(); input.brand = "需要明确选择的回退"; input.stage = .return
  _ = try source.perform(.create(input), now: testNow)
  let seed = try source.pendingDocuments(); try target.receive(seed)
  for doc in seed { try source.acknowledge(doc, serverFields: "seed") }
  _ = try source.perform(.transition(id: input.id, stage: .submit,
    expectedRevision: source.snapshot().orders[0].workflowRevision), now: testNow.addingTimeInterval(20))
  _ = try target.perform(.transition(id: input.id, stage: .review,
    expectedRevision: target.snapshot().orders[0].workflowRevision), now: testNow.addingTimeInterval(10))
  try target.receive(source.pendingDocuments())
  let conflict = try #require(target.snapshot().conflicts.first)
  try target.receive(seed)
  #expect(try target.snapshot().conflicts.count == 1)
  #expect(try b.photos().snapshot().conflicts.count == 1)
  for _ in 0..<2 {
    _ = try target.perform(.resolveConflict(id: conflict.id, keepLocal: false,
      expectedRevision: conflict.revision), now: testNow)
  }
  #expect(try target.snapshot().conflicts.isEmpty)
  #expect(try target.snapshot().orders[0].stage == .submit)
}

@Test func unreadableLegacyArchiveDoesNotBlockWorkspaceOrLoseItsRawContent() throws {
  let f = try Fixture()
  defer { f.clean() }
  let engine = try f.workspace()
  let id = UUID().uuidString.lowercased()
  let raw = "保留下来的旧格式内容，仍可复制或导出"
  try engine.db.insert("wb_sync_conflicts", ["id": .string(id), "entity": .string("legacy-notes"),
    "record_id": .string("old-id"), "payload": .string(raw), "created_at": .string(Clock.stamp())])
  let reopened = try f.workspace()
  let saved = try #require(reopened.snapshot().conflicts.first)
  #expect(saved.local == .string(raw))
  _ = try reopened.perform(.resolveConflict(id: id, choice: .current, expectedRevision: saved.revision), now: testNow)
  #expect(try reopened.snapshot().conflicts.isEmpty)
}

@Test func deletedTaskIgnoresMetadataOnlyReplayButKeepsRealRemoteEdits() throws {
  let a = try Fixture(), b = try Fixture()
  defer { a.clean(); b.clean() }
  let source = try a.workspace(), target = try b.workspace()
  let id = try source.perform(.create(.tasks, fields: [.title: .string("准备删除")]), now: testNow).id!
  var document = try #require(source.pendingDocuments().first)
  try target.receive([document])
  _ = try target.perform(.delete(.tasks, id: id), now: testNow)
  document.payload["updated_at"] = .string(Clock.stamp(testNow.addingTimeInterval(20)))
  try target.receive([document])
  #expect(try target.snapshot().conflicts.isEmpty && target.snapshot()[.tasks].isEmpty)
  document.payload["title"] = .string("另一端的实际新内容")
  try target.receive([document]); try target.receive([document])
  #expect(try target.snapshot().conflicts.count == 1)
  #expect(try target.snapshot().conflicts[0].local["title"] == .string("另一端的实际新内容"))
  #expect(try target.pendingDocuments().contains { $0.id == id && $0.payload.isNull })
}
