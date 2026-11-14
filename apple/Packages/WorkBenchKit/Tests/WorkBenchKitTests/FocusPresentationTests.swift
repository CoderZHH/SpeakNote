import Foundation
import Testing
import WorkBenchActivity

@testable import WorkBenchKit

@Test func focusSurfacesCountUpImmediatelyAndPreservePauseTime() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let task = try db.perform(.create(.tasks, fields: [.title: .string("专注测试")]), now: testNow).id!
  let id = try db.perform(.startFocus(taskID: task), now: testNow).id!
  let first = try #require(FocusPresentation.current(in: db.snapshot()))
  #expect(first.id == id && first.timer.title == "专注测试")
  #expect(first.timer.elapsed(at: testNow.addingTimeInterval(90)) == 90)
  #expect(first.timer.timerStart == testNow)
  #expect(
    calendarEntries(snapshot: try db.snapshot(), day: testNow, now: testNow.addingTimeInterval(90))
      .isEmpty)
  _ = try db.perform(.pauseFocus, now: testNow.addingTimeInterval(120))
  let paused = try #require(FocusPresentation.current(in: db.snapshot()))
  #expect(!paused.timer.isRunning && paused.timer.timerStart == nil)
  #expect(paused.timer.elapsed(at: testNow.addingTimeInterval(600)) == 120)
  _ = try db.perform(.startFocus(taskID: task), now: testNow.addingTimeInterval(600))
  let repeated = try db.perform(.startFocus(taskID: task), now: testNow.addingTimeInterval(610))
  let resumed = try #require(FocusPresentation.current(in: db.snapshot()))
  #expect(repeated.alreadyRunning && resumed.id == id)
  #expect(resumed.timer.elapsed(at: testNow.addingTimeInterval(630)) == 150)
  #expect(resumed.timer.elapsedText(at: testNow.addingTimeInterval(630)) == "00:02:30")
  #expect(resumed.timer.timerStart == testNow.addingTimeInterval(480))
  #expect(try db.snapshot()[.focusIntervals].count == 2)
  _ = try db.perform(.endFocus(id: id, resumeHint: nil), now: testNow.addingTimeInterval(700))
  #expect(try FocusPresentation.current(in: db.snapshot()) == nil)
  #expect(try db.db.record("focus_sessions", id: id).integer("elapsed_seconds") == 220)
}

@Test func focusSurfacePrefersRunningSessionAndUsesRenamedTask() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let a = try db.perform(.create(.tasks, fields: [.title: .string("任务 A")]), now: testNow).id!
  let b = try db.perform(.create(.tasks, fields: [.title: .string("任务 B")]), now: testNow).id!
  let first = try db.perform(.startFocus(taskID: a), now: testNow).id!
  _ = try db.perform(.startFocus(taskID: b), now: testNow.addingTimeInterval(10))
  _ = try db.perform(.startFocus(taskID: a), now: testNow.addingTimeInterval(20))
  _ = try db.perform(
    .update(.tasks, id: a, fields: [.title: .string("改名后的任务")]), now: testNow.addingTimeInterval(21)
  )
  let current = try #require(FocusPresentation.current(in: db.snapshot()))
  #expect(current.id == first && current.timer.isRunning)
  #expect(current.timer.title == "改名后的任务")
  #expect(current.timer.elapsed(at: testNow.addingTimeInterval(30)) == 20)
  _ = try db.perform(.pauseFocus, now: testNow.addingTimeInterval(40))
  #expect(try FocusPresentation.current(in: db.snapshot())?.id == first)
  _ = try db.perform(.endFocus(id: first, resumeHint: nil), now: testNow.addingTimeInterval(50))
  #expect(try db.snapshot()[.focusSessions].contains { $0.status == "paused" })
  #expect(try FocusPresentation.current(in: db.snapshot()) == nil)
}

@Test func focusTimerHandlesClockSkewAndHoursWithoutRewritingData() {
  let state = FocusTimerState(
    title: "自由专注", accumulatedSeconds: 3661, activeSince: testNow, isRunning: true)
  #expect(state.elapsedText(at: testNow.addingTimeInterval(-30)) == "01:01:01")
  #expect(state.elapsedText(at: testNow.addingTimeInterval(60)) == "01:02:01")
  let paused = FocusTimerState(
    title: "自由专注", accumulatedSeconds: 3661, activeSince: nil, isRunning: false)
  #expect(paused.elapsedText(at: testNow.addingTimeInterval(86400)) == "01:01:01")
}
