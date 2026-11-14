import SwiftUI

func courseReminderRows(snapshot: WorkspaceSnapshot, now: Date, minutes: Int) -> [JSONValue] {
  guard [5, 10, 15, 30].contains(minutes) else { return [] }
  var rows: [JSONValue] = []
  for offset in 0..<280 {
    let day = Clock.calendar.date(byAdding: .day, value: offset, to: now)!
    for occurrence in courseOccurrences(snapshot: snapshot, day: day) {
      guard let start = try? Clock.parse(Clock.day(day) + "T" + occurrence.start + ":00+08:00")
      else { continue }
      let at = start.addingTimeInterval(-Double(minutes) * 60)
      if at <= now { continue }
      rows.append(
        .object([
          "id": .string("workbench-course:" + occurrence.meeting.id + ":" + Clock.day(day)),
          "title": .string(occurrence.course.title + " · \(minutes) 分钟后上课"),
          "body": .string(
            occurrence.start + " · " + occurrence.meeting[.room].string
              + " · 第 \(occurrence.meeting[.periodStart].int)–\(occurrence.meeting[.periodEnd].int) 节"
          ), "at": .string(Clock.stamp(at)),
        ]))
    }
    if rows.count >= 60 { break }
  }
  return Array(rows.sorted { $0["at"].string < $1["at"].string }.prefix(60))
}
struct CourseRemindersView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var minutes = 0
  @State private var message = ""
  var body: some View {
    NavigationStack {
      Form {
        Picker("上课前提醒", selection: $minutes) {
          Text("关闭").tag(0)
          ForEach([5, 10, 15, 30], id: \.self) { Text("提前 \($0) 分钟").tag($0) }
        }
        if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
      }.navigationTitle("课程提醒").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            session.run {
              let result = try await session.refreshCourseReminders(minutes: minutes)
              message = result["message"].string
              if minutes == 0 || result["authorized"].bool { dismiss() }
            }
          }
        }
      }.task {
        minutes =
          Int(
            (try? await session.workspace?.database.syncSetting("course.reminder_minutes"))?.string
              ?? "0") ?? 0
      }
    }
  }
}
extension AppSession {
  @discardableResult func refreshCourseReminders(minutes: Int? = nil) async throws -> JSONValue {
    guard let store = workspace else { throw WorkBenchError("拍照助手不能访问个人课程") }
    let previous = Int(try await store.database.syncSetting("course.reminder_minutes").string) ?? 0
    let next = minutes ?? previous
    if next == 0 && minutes == nil { return .object([:]) }
    try require([0, 5, 10, 15, 30].contains(next), "提醒时间不正确")
    if minutes != nil && next > 0 {
      do { try await reminders.requestAuthorization() } catch {
        return .object(["authorized": .bool(false), "message": .string(error.localizedDescription)])
      }
    }
    try await store.database.setSyncSetting("course.reminder_minutes", value: .string(String(next)))
    await refreshWorkspaceReminders(force: true, courseMinutes: next)
    return .object([
      "authorized": .bool(reminders.issue == nil),
      "message": .string(reminders.issue ?? (next == 0 ? "课程提醒已关闭" : "上课前提醒已开启")),
    ])
  }
}
