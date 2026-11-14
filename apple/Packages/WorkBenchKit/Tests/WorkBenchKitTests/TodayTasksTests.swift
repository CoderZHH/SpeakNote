import Foundation
import Testing

@testable import WorkBenchKit

@Test func todayCompletionUsesShanghaiDayAndSurvivesEditsAndReopen() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let yesterday = try Clock.parse("2026-11-03T23:59:59+08:00")
  let midnight = yesterday.addingTimeInterval(1)
  let evening = try Clock.parse("2026-11-04T23:59:59+08:00")
  func create(_ title: String) throws -> String {
    try db.perform(.create(.tasks, fields: [
      .title: .string(title), .plannedDate: .string("2026-11-01"),
    ]), now: yesterday).id!
  }
  let old = try create("昨天完成")
  let early = try create("今天零点完成的旧安排")
  let latest = try create("今天最后完成")
  let pending = try create("仍未完成")
  for (id, at) in [(old, yesterday), (early, midnight), (latest, evening)] {
    _ = try db.perform(.update(.tasks, id: id, fields: [.status: .string("done")]), now: at)
  }
  _ = try db.perform(.update(.tasks, id: old, fields: [.notes: .string("今天改备注")]), now: evening)
  var rows = try db.snapshot()[.tasks]
  #expect(tasksCompleted(on: midnight, in: rows).map(\.id) == [latest, early])
  #expect(tasksCompleted(on: yesterday, in: rows).map(\.id) == [old])
  #expect(tasksCompleted(on: evening.addingTimeInterval(1), in: rows).isEmpty)
  _ = try db.perform(.update(.tasks, id: early, fields: [.status: .string("todo")]), now: evening)
  rows = try f.workspace().snapshot()[.tasks]
  #expect(tasksCompleted(on: evening, in: rows).map(\.id) == [latest])
  #expect(rows.first { $0.id == pending }?.status == "todo")
}
