import Foundation
import Testing
@testable import WorkBenchKit

@Test func photoConflictAllowsIndependentEditsAndResolutionPreservesBothSides() throws {
  for keepLocal in [true, false] {
    let a = try Fixture(), b = try Fixture()
    defer { a.clean(); b.clean() }
    let source = try a.photos(), target = try b.photos()
    try source.bind(a.space)
    try target.bind(a.space)
    var input = PhotoOrderInput()
    input.brand = "原品牌"
    _ = try source.perform(.create(input), now: testNow)
    let seed = try source.pendingDocuments()
    try target.receive(seed)
    for doc in seed { try source.acknowledge(doc, serverFields: "seed") }
    _ = try source.perform(.patch(id: input.id, field: .brand, before: .string("原品牌"), value: .string("共享品牌")), now: testNow)
    _ = try source.perform(.patch(id: input.id, field: .commission, before: .null, value: .integer(3600)), now: testNow)
    _ = try target.perform(.patch(id: input.id, field: .brand, before: .string("原品牌"), value: .string("本机品牌")), now: testNow)
    try target.receive(source.pendingDocuments())
    let conflict = try target.snapshot().conflicts.first!
    #expect(!conflict.base.isNull)
    #expect(throws: WorkBenchError.self) {
      _ = try target.perform(.patch(id: input.id, field: .brand, before: .string("本机品牌"), value: .string("待提交输入")), now: testNow)
    }
    // Clicking Done without edits is harmless even on a conflicted field.
    _ = try target.perform(.patch(id: input.id, field: .brand, before: .string("本机品牌"), value: .string("本机品牌")), now: testNow)
    _ = try target.perform(.patch(id: input.id, field: .notes, before: .string(""), value: .string("核对期间新填备注")), now: testNow)
    #expect(try target.snapshot().orders[0][.notes] == .string("核对期间新填备注"))
    #expect(try target.snapshot().conflicts.count == 1)
    #expect(try !target.pendingDocuments().contains { $0.id == "order:" + input.id })
    #expect(throws: WorkBenchError.self) {
      _ = try target.perform(.resolveConflict(id: conflict.id, keepLocal: keepLocal, expectedRevision: conflict.revision), now: testNow)
    }
    let current = try target.snapshot().conflicts.first!
    _ = try target.perform(.resolveConflict(id: current.id, keepLocal: keepLocal, expectedRevision: current.revision), now: testNow)
    let reopened = try PhotoEngine(url: b.directory.appendingPathComponent("photo.sqlite")).snapshot()
    #expect(reopened.conflicts.isEmpty)
    #expect(reopened.orders[0].brand == (keepLocal ? "本机品牌" : "共享品牌"))
    #expect(reopened.orders[0][.notes] == .string("核对期间新填备注"))
    #expect(reopened.orders[0][.commission] == .integer(3600))
    #expect(try target.pendingDocuments().contains { $0.id == "order:" + input.id })
  }
}
