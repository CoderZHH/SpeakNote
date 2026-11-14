import SwiftUI

struct CalendarEntry: Identifiable {
  let id: String
  let title: String
  let start: Date
  let end: Date
  let kind: Kind
  var room: String? = nil
  var inactiveLabel: String? = nil
  var displayTitle: String {
    [title, room].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }
  enum Kind {
    case task(WorkspaceItem)
    case focus(WorkspaceItem, String?)
    case completed(WorkspaceItem)
    case course(WorkspaceItem)
  }
  var color: Color {
    if inactiveLabel != nil { return .secondary }
    switch kind {
    case .task: return .blue
    case .focus: return .indigo
    case .completed: return .teal
    case .course: return .orange
    }
  }
}
func calendarEntries(snapshot: WorkspaceSnapshot, day: Date, now: Date) -> [CalendarEntry] {
  let beginning = Clock.calendar.startOfDay(for: day)
  let until = Clock.calendar.date(byAdding: .day, value: 1, to: beginning)!
  let date = Clock.day(day)
  var entries: [CalendarEntry] = []
  for task in snapshot[.tasks] {
    if task[.plannedDate].string == date && !task[.startTime].isNull,
      let start = try? Clock.parse(date + "T" + task[.startTime].string + ":00+08:00"),
      let end = try? Clock.parse(date + "T" + task[.endTime].string + ":00+08:00")
    {
      entries.append(
        CalendarEntry(
          id: "plan:" + task.id, title: task.title, start: start, end: end, kind: .task(task)))
    }
    if task.status == "done", let at = try? Clock.parse(task.fields.text("completed_at")),
      at >= beginning && at < until
    {
      entries.append(
        CalendarEntry(
          id: "done:" + task.id, title: task.title, start: at,
          end: min(until, at.addingTimeInterval(600)), kind: .completed(task)))
    }
  }
  for focus in snapshot[.focusSessions] {
    let running = focus.status == "running"
    let active = try? Clock.parse(focus.fields.text("active_since"))
    let total =
      focus.fields.integer("elapsed_seconds")
      + (running ? Int64(max(0, now.timeIntervalSince(active ?? now))) : 0)
    if total < 600 { continue }
    let intervals = snapshot[.focusIntervals].filter { $0.fields.text("focus_id") == focus.id }
    let title = snapshot.item(.tasks, focus.fields.text("task_id"))?.title ?? "自由专注"
    for interval in intervals.isEmpty ? [focus] : intervals {
      guard let from = try? Clock.parse(interval.fields.text("started_at")) else { continue }
      let to = (try? Clock.parse(interval.fields.text("ended_at"))) ?? (running ? now : from)
      if from < until && to > beginning {
        entries.append(
          CalendarEntry(
            id: interval.id, title: title, start: max(beginning, from), end: min(until, to),
            kind: .focus(focus, intervals.isEmpty ? nil : interval.id)))
      }
    }
  }
  entries += courseOccurrences(snapshot: snapshot, day: day).compactMap(\.calendarEntry)
  return entries.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
}
struct CalendarLane {
  let event: CalendarEntry
  var lane: Int
  var count: Int
}
func calendarLanes(_ events: [CalendarEntry], minimumDuration: TimeInterval = 0) -> [CalendarLane] {
  var output: [CalendarLane] = []
  var group: [CalendarLane] = []
  var ends: [Date] = []
  var groupEnd = Date.distantPast
  func flush() {
    let count = max(1, ends.count)
    output += group.map {
      var v = $0
      v.count = count
      return v
    }
    group = []
    ends = []
  }
  for event in events {
    if event.start >= groupEnd { flush() }
    let lane = ends.firstIndex { $0 <= event.start } ?? ends.count
    let end = max(event.end, event.start.addingTimeInterval(minimumDuration))
    if lane == ends.count { ends.append(end) } else { ends[lane] = end }
    group.append(CalendarLane(event: event, lane: lane, count: 1))
    groupEnd = max(groupEnd, end)
  }
  flush()
  return output
}
struct WeekCalendar: View {
  let day: Date
  let snapshot: WorkspaceSnapshot
  @Environment(\.openCollection) private var openCollection
  @State private var selectedTask: WorkspaceItem?
  @State private var selectedFocus: WorkspaceItem?
  @State private var selectedInterval: String?
  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let days = timelineWeek(containing: day)
      WeekTimeline(
        days: days, hours: 0...24, initialHour: 8, now: context.date,
        entries: days.flatMap { calendarEntries(snapshot: snapshot, day: $0, now: context.date) },
        select: select)
    }
    .sheet(item: $selectedTask) { ScheduleEditor(item: $0) }
    .sheet(item: $selectedFocus) {
      FocusCorrectionView(focus: $0, preferredIntervalID: selectedInterval)
    }
  }
  func select(_ entry: CalendarEntry) {
    switch entry.kind {
    case .task(let task), .completed(let task): selectedTask = task
    case .focus(let focus, let interval):
      selectedInterval = interval
      selectedFocus = focus
    case .course(let course): openCollection?(.init(entity: .courses, id: course.id))
    }
  }
}
