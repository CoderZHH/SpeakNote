#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WorkBenchKit

// Opt-in native rendering with synthetic data; never launches the installed app.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WORKBENCH_COLLECTION_PREVIEW"] == "1"))
@MainActor func collectionDetailNativePreview() async throws {
  try require(ProcessInfo.processInfo.environment["WORKBENCH_QA"] == "1", "Preview requires cloud disabled")
  let f = try Fixture()
  defer { f.clean() }
  let engine = try f.workspace()
  let project = try engine.perform(.create(.projects, fields: [.title: .string("DailyChange")]), now: .now).id!
  for name in ["ASO", "美化制作贴纸（相机）的轮廓和条子", "封面", "教程", "宣传视频：参考拍摄效果，整理分镜与配乐。https://example.com/preview/a-very-long-link-for-layout-checking", "导出照片优化"] {
    _ = try engine.perform(.create(.tasks, fields: [.title: .string(name), .projectID: .string(project)]), now: .now)
  }
  _ = try engine.perform(.create(.tasks, fields: [.title: .string("已完成的准备工作"), .projectID: .string(project), .status: .string("done")]), now: .now)
  _ = try engine.perform(.installTimetable, now: .now)
  let term = try #require(engine.snapshot()[.semesters].first)
  let ninthWeek = try Clock.parse("2026-11-09T00:00:00+08:00")
  let completedBeforeWeek = ninthWeek.addingTimeInterval(-86400)
  let courseID = try #require(engine.perform(.create(.courses, fields: [
    .title: .string("人工智能与大数据系统设计"), .teacher: .string("示例教师"),
    .semesterID: .string(term.id),
  ]), now: completedBeforeWeek).id)
  _ = try engine.perform(.create(.courseMeetings, fields: [
    .courseID: .string(courseID), .weekday: .integer(1), .room: .string("2-111"),
    .periodStart: .integer(1), .periodEnd: .integer(4), .weeks: .array([.integer(9)]),
  ]), now: completedBeforeWeek)
  _ = try engine.perform(
    .update(.courses, id: courseID, fields: [.status: .string("done")]), now: completedBeforeWeek)
  _ = try engine.perform(.update(.courses, id: courseID, fields: [
    .description: .string("课程资料和课堂记录放在这里。较长的备注会自然换行，课程待办的附件仍保存在对应条目下。"),
  ]), now: completedBeforeWeek)
  for title in ["完成拍摄准备", "核对订单要求，这是一条比较长的已完成任务，用来检查窄窗口中的自然换行与操作位置"] {
    let id = try engine.perform(.create(.tasks, fields: [.title: .string(title), .projectID: .string(project)]), now: .now).id!
    _ = try engine.perform(.update(.tasks, id: id, fields: [.status: .string("done")]), now: .now)
  }
  let empty = try engine.perform(.create(.learning, fields: [.title: .string("学习计划")]), now: .now).id!
  setenv("WORKBENCH_DB_PATH", f.directory.appendingPathComponent("workbench.sqlite").path, 1)
  let session = AppSession(role: .workbench)
  await session.start()
  try require(session.workspace != nil, session.error ?? "Preview failed")
  NSApplication.shared.setActivationPolicy(.accessory)
  let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 850),
    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close(); window.contentViewController = nil }
  for (name, entity, id, width) in [("wide", WorkspaceEntity.projects, project, 1100.0), ("narrow", .projects, project, 430.0), ("empty-learning", .learning, empty, 850.0)] {
    window.setContentSize(NSSize(width: width, height: 850))
    let host = NSHostingController(rootView: NavigationStack {
      CollectionDetail(route: .init(entity: entity, id: id))
    }.environment(session).frame(width: width, height: 850))
    window.contentViewController = host
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(400))
    host.view.layoutSubtreeIfNeeded()
    let image = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
    host.view.cacheDisplay(in: host.view.bounds, to: image)
    try #require(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/workbench-collection-" + name + ".png"))
    #expect(host.view.bounds.width.isFinite && host.view.bounds.height.isFinite)
  }
  let course = try #require(session.workspace?.snapshot.item(.courses, courseID))
  for (name, page, width) in [
    ("course-detail", AnyView(CollectionDetail(route: .init(entity: .courses, id: courseID))), 520.0),
    ("month", AnyView(MonthCalendar(day: .constant(.now), snapshot: session.workspace!.snapshot, now: .now, expanded: true)), 1050.0),
    ("week", AnyView(WeekCalendar(day: .now, snapshot: session.workspace!.snapshot)), 1050.0),
    ("courses", AnyView(CoursesView()), 1050.0),
    ("course-week-nine", AnyView(CourseSchedule(week: ninthWeek, semesterID: term.id) { _ in }.workspacePage()), 1050.0),
    ("course-week-narrow", AnyView(CourseSchedule(week: ninthWeek, semesterID: term.id) { _ in }.workspacePage()), 430.0),
    ("course-week-empty", AnyView(CourseSchedule(week: .distantPast, semesterID: term.id) { _ in }.workspacePage()), 430.0),
    ("course-card", AnyView(ScrollView {
      CollectionBoardLayout {
        ForEach(session.workspace!.snapshot[.courses].prefix(4)) { item in
          CourseCard(item: item) {}
        }
      }
    }.workspacePage()), 1050.0),
    ("course-card-narrow", AnyView(ScrollView {
      CourseCard(item: course) {}
    }.workspacePage()), 340.0),
    ("date", AnyView(WorkspaceDateField(title: "安排日期", selection: .constant(.now)).padding(24)), 1050.0),
    ("today-wide", AnyView(TodayView()), 1100.0),
    ("today-narrow", AnyView(TodayView()), 430.0)
  ] {
    window.setContentSize(NSSize(width: width, height: 800))
    let host = NSHostingController(rootView: NavigationStack { page.background(WorkbenchDesign.canvas) }.environment(session).frame(width: width, height: 800))
    window.contentViewController = host
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(400))
    host.view.layoutSubtreeIfNeeded()
    let image = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
    host.view.cacheDisplay(in: host.view.bounds, to: image)
    try #require(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/workbench-calendar-" + name + ".png"))
  }

}
#endif
