import Foundation
import Testing

@testable import WorkBenchKit

@Test func monthCalendarKeepsWeekdayColumnsAndLeapDays() throws {
  for value in ["2026-10-28", "2027-02-15", "2028-02-15", "2026-08-31", "2027-01-01"] {
    let date = try Clock.parse(value + "T12:00:00+08:00")
    let month = CalendarMonth(date)
    #expect(month.days.count % 7 == 0)
    #expect(Clock.calendar.component(.weekday, from: month.days.first!) == 2)
    #expect(Clock.calendar.component(.weekday, from: month.days.last!) == 1)
    let actual = month.days.filter { month.contains($0) }
    #expect(actual.count == Clock.calendar.range(of: .day, in: .month, for: date)!.count)
    #expect(Clock.calendar.component(.day, from: actual.first!) == 1)
    for (first, second) in zip(month.days, month.days.dropFirst()) {
      #expect(Clock.calendar.dateComponents([.day], from: first, to: second).day == 1)
    }
  }
}

@Test func dayAgendaIncludesUntimedPlansAndClipsFocusAcrossMidnight() throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try f.workspace()
  let start = try Clock.parse("2026-10-28T23:50:00+08:00")
  let tomorrow = start.addingTimeInterval(1200)
  let task = try db.perform(
    .create(.tasks, fields: [.title: .string("全天计划"), .plannedDate: .string("2026-10-29")]),
    now: start
  ).id!
  let focus = try db.perform(.startFocus(taskID: nil), now: start).id!
  _ = try db.perform(.endFocus(id: focus, resumeHint: nil), now: tomorrow)
  let snapshot = try db.snapshot()
  let content = CalendarDayContent(snapshot: snapshot, day: tomorrow, now: tomorrow)
  #expect(content.untimedTasks.map(\.id) == [task])
  #expect(content.entries.count == 1)
  #expect(Clock.day(content.entries[0].start) == "2026-10-29")
  #expect(content.entries[0].end.timeIntervalSince(content.entries[0].start) == 600)
  let before = CalendarDayContent(snapshot: snapshot, day: start, now: tomorrow)
  #expect(before.untimedTasks.isEmpty)
  #expect(before.entries.count == 1)
  let empty = CalendarDayContent(
    snapshot: snapshot, day: tomorrow.addingTimeInterval(86400), now: tomorrow)
  #expect(empty.isEmpty)
}

@Test func calendarZoomAlwaysStaysFiniteAndBounded() {
  for n: CGFloat in [0, -1, .infinity, .nan, 0.2, 2, 10000] {
    let week = CalendarZoom.clamped(n, lower: 32, upper: 160)
    let month = CalendarZoom.clamped(n, lower: 1, upper: 3)
    #expect(week.isFinite && (32...160).contains(week))
    #expect(month.isFinite && (1...3).contains(month))
  }
}

@Test func weeklyTimetableShowsCompletedCourseWithoutRestoringItsReminders() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let db = try fixture.workspace()
  let now = try Clock.parse("2026-11-03T12:00:00+08:00")
  let monday = try Clock.parse("2026-11-09T00:00:00+08:00")
  _ = try db.perform(.installTimetable, now: now)
  let term = try #require(db.snapshot()[.semesters].first)
  let course = try #require(db.perform(.create(.courses, fields: [
    .title: .string("新增课程"), .semesterID: .string(term.id),
  ]), now: now).id)
  _ = try db.perform(.create(.courseMeetings, fields: [
    .courseID: .string(course), .weekday: .integer(1),
    .periodStart: .integer(1), .periodEnd: .integer(4), .weeks: .array([.integer(9)]),
  ]), now: now)
  _ = try db.perform(.update(.courses, id: course, fields: [.status: .string("done")]), now: now)
  let snapshot = try db.snapshot()
  let reference = try #require(courseOccurrences(
    snapshot: snapshot, day: monday, allWeek: true, includeInactive: true
  ).first { $0.course.id == course })
  #expect(reference.inactiveLabel == "已完结")
  #expect(reference.start == "08:00" && reference.end == "11:40")
  #expect(!courseOccurrences(snapshot: snapshot, day: monday).contains { $0.course.id == course })
  #expect(!courseReminderRows(snapshot: snapshot, now: now, minutes: 15).contains {
    $0["title"].string.hasPrefix("新增课程")
  })
  _ = try db.perform(.update(.courses, id: course, fields: [.status: .string("active")]), now: now)
  let restored = try db.snapshot()
  #expect(courseOccurrences(snapshot: restored, day: monday).contains {
    $0.course.id == course && $0.inactiveLabel == nil
  })
}
