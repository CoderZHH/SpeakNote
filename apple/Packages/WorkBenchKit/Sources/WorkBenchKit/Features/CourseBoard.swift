import SwiftUI

struct CourseSchedule: View {
  let week: Date
  let semesterID: String
  var hasUnscheduledCourses = false
  var isCurrentWeek = true
  var onBackToCurrentWeek: (() -> Void)? = nil
  var onShowCourseCards: (() -> Void)? = nil
  var onAddCourse: (() -> Void)? = nil
  let open: (WorkspaceItem) -> Void
  @Environment(AppSession.self) private var session

  var body: some View {
    let rows = courseOccurrences(
      snapshot: session.workspace?.snapshot ?? .init(), day: week, allWeek: true,
      includeInactive: true
    ).filter { $0.course[.semesterID].string == semesterID }
    Group {
      if rows.isEmpty {
        ContentUnavailableView {
          Label(
            hasUnscheduledCourses ? "本学期课程尚未设置上课时间" : "本周没有上课安排",
            systemImage: "calendar"
          )
        } description: {
          Text(
            hasUnscheduledCourses
              ? "切换到「课程」卡片即可为每门课设置周次、节次与教室。"
              : "可以切换其他教学周查看，或添加新课程。"
          )
        } actions: {
          HStack(spacing: WorkbenchDesign.Space.small) {
            if hasUnscheduledCourses, let onShowCourseCards {
              Button("去课程卡片设置排课", action: onShowCourseCards)
                .buttonStyle(.borderedProminent)
            } else if !isCurrentWeek, let onBackToCurrentWeek {
              Button("回到本周", action: onBackToCurrentWeek)
                .buttonStyle(.bordered)
            }
            if let onAddCourse {
              Button("添加课程", action: onAddCourse)
                .buttonStyle(.bordered)
            }
          }
        }
      } else {
        weekBoard(rows)
      }
    }
    .environment(\.timeZone, Clock.calendar.timeZone)
  }

  private func weekBoard(_ rows: [CourseOccurrence]) -> some View {
    let entries = rows.compactMap(\.calendarEntry)
    let first = (rows.compactMap { timeMinutes($0.start) }.min() ?? 480) / 60
    let last = max(first + 1, ((rows.compactMap { timeMinutes($0.end) }.max() ?? 1020) + 59) / 60)
    return TimelineView(.periodic(from: .now, by: 60)) { context in
      WeekTimeline(days: timelineWeek(containing: week), hours: first...last, now: context.date, entries: entries) { event in
        if case .course(let course) = event.kind { open(course) }
      }
    }
  }
}

extension CourseOccurrence {
  var calendarEntry: CalendarEntry? {
    guard let from = timeMinutes(start), let until = timeMinutes(end), until > from else { return nil }
    let midnight = Clock.calendar.startOfDay(for: day)
    return CalendarEntry(
      id: id, title: course.title, start: midnight.addingTimeInterval(Double(from) * 60),
      end: midnight.addingTimeInterval(Double(until) * 60), kind: .course(course),
      room: meeting[.room].string, inactiveLabel: inactiveLabel)
  }
}

struct CourseScheduleStatus: View {
  let course: WorkspaceItem
  @Environment(AppSession.self) private var session

  var body: some View {
    if course.status == "done" || course.status == "paused" {
      HStack(spacing: WorkbenchDesign.Space.small) {
        Text(course.status == "done" ? "已完结" : "已暂停").foregroundStyle(.secondary)
        Button("恢复排课") {
          session.run {
            _ = try await session.workspace?.perform(
              .update(.courses, id: course.id, fields: [.status: .string("active")]))
          }
        }.buttonStyle(.plain).foregroundStyle(.tint)
      }.font(.caption)
    }
  }
}

struct CourseMeetingSummary: View {
  let meeting: WorkspaceItem
  let semester: WorkspaceItem?
  var compact = false
  private var weekday: String {
    let index = Int(meeting[.weekday].int)
    return (1...7).contains(index) ? ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][index - 1] : ""
  }
  private var period: String {
    let start = meeting[.periodStart].int
    let end = meeting[.periodEnd].int
    return start == end ? "第 \(start) 节" : "第 \(start)–\(end) 节"
  }
  private var time: String {
    let periods = (try? JSONValue(json: semester?[.periods].string ?? "[]").array) ?? []
    guard
      let start = periods.first(where: { $0["number"] == meeting[.periodStart] })?["start"].string,
      let end = periods.first(where: { $0["number"] == meeting[.periodEnd] })?["end"].string
    else { return period }
    return start + "–" + end
  }
  private var weeks: String {
    let numbers = Array(
      Set((try? JSONValue(json: meeting[.weeks].string).array.map { Int($0.int) }) ?? [])
    ).sorted()
    var ranges: [String] = []
    var index = 0
    while index < numbers.count {
      let start = numbers[index]
      var end = start
      while index + 1 < numbers.count && numbers[index + 1] == end + 1 {
        index += 1
        end = numbers[index]
      }
      ranges.append(start == end ? "\(start)" : "\(start)–\(end)")
      index += 1
    }
    return ranges.isEmpty ? "" : "第 " + ranges.joined(separator: "、") + " 周"
  }
  var body: some View {
    Group {
      if compact {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: WorkbenchDesign.Space.small) {
            timeLabel
            location
            if !weeks.isEmpty { Text(weeks) }
          }.fixedSize(horizontal: true, vertical: false)
          stacked
        }.font(.subheadline).foregroundStyle(.secondary)
      } else {
        stacked
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, compact ? 0 : WorkbenchDesign.rowInset)
      .contentShape(Rectangle())
  }
  private var timeLabel: some View {
    HStack(spacing: WorkbenchDesign.Space.small) {
      Text(weekday).fontWeight(.medium)
      Text(time).monospacedDigit()
    }.foregroundStyle(.primary)
  }
  private var stacked: some View {
    VStack(alignment: .leading, spacing: compact ? 4 : WorkbenchDesign.Space.small) {
      timeLabel.font(compact ? .subheadline : .body)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: WorkbenchDesign.Space.medium) {
          location
          Text(weeks)
        }
        VStack(alignment: .leading, spacing: 4) {
          location
          Text(weeks)
        }
      }.font(compact ? .caption : .subheadline).foregroundStyle(.secondary)
    }
  }
  @ViewBuilder private var location: some View {
    if !meeting[.room].string.isEmpty { Label(meeting[.room].string, systemImage: "mappin") }
  }
}
