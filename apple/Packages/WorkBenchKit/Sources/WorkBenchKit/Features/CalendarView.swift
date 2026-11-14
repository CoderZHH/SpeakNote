import SwiftUI

struct CalendarView: View {
  @Environment(AppSession.self) private var session
  @State private var day = Date()
  #if os(macOS)
    @State private var weekView = true
  #else
    @State private var weekView = false
  #endif
  @State private var selectedFocus: WorkspaceItem?
  @State private var selectedInterval: String?
  @State private var selectedTask: WorkspaceItem?
  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  var body: some View {
    VStack(spacing: WorkbenchDesign.Space.section) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: WorkbenchDesign.Space.medium) {
          monthHeading
          Spacer(minLength: 0)
          calendarControls
        }
        VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
          monthHeading
          HStack {
            calendarControls
            Spacer(minLength: 0)
          }
        }
      }
      if weekView {
        WeekCalendar(day: day, snapshot: snapshot)
      } else {
        monthContent
      }
    }.workspacePage()

      .sheet(item: $selectedFocus) {
        FocusCorrectionView(focus: $0, preferredIntervalID: selectedInterval)
      }
      .sheet(item: $selectedTask) { ScheduleEditor(item: $0) }
  }
  private var monthHeading: some View {
    Text(day, format: .dateTime.year().month()).font(WorkbenchDesign.Typography.title)
      .accessibilityIdentifier("calendar.month.heading").fixedSize()
  }
  private var calendarControls: some View {
    HStack(spacing: WorkbenchDesign.Space.medium) {
      WorkspaceFilters(values: [true, false], selection: $weekView, title: { $0 ? "周" : "月" })
      Button("上一页", systemImage: "chevron.left") { move(-1) }.labelStyle(.iconOnly)
        .accessibilityIdentifier("calendar.previous")
      Button("今天") { day = .now }.accessibilityIdentifier("calendar.today")
      Button("下一页", systemImage: "chevron.right") { move(1) }.labelStyle(.iconOnly)
        .accessibilityIdentifier("calendar.next")
    }.fixedSize()
  }
  private var monthContent: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      GeometryReader { geometry in
        #if os(macOS)
          if geometry.size.width >= WorkbenchDesign.CalendarLayout.splitWidth {
            HStack(alignment: .top, spacing: WorkbenchDesign.Space.group) {
              MonthCalendar(day: $day, snapshot: snapshot, now: context.date, expanded: true)
              Divider()
              agenda(now: context.date).frame(width: WorkbenchDesign.CalendarLayout.agendaWidth)
            }
          } else {
            compactMonth(now: context.date)
          }
        #else
          compactMonth(now: context.date)
        #endif
      }
    }
  }
  private func compactMonth(now: Date) -> some View {
    VStack(spacing: WorkbenchDesign.Space.section) {
      MonthCalendar(day: $day, snapshot: snapshot, now: now, expanded: false)
        .frame(
          height: CGFloat(CalendarMonth(day).days.count / 7)
            * WorkbenchDesign.CalendarLayout.dayHeight
            + WorkbenchDesign.CalendarLayout.weekdayHeight)
      Divider()
      agenda(now: now)
    }
  }
  private func agenda(now: Date) -> some View {
    CalendarDayAgenda(day: day, snapshot: snapshot, now: now) { entry in
      switch entry.kind {
      case .task(let task), .completed(let task): selectedTask = task
      case .focus(let focus, let interval):
        selectedInterval = interval
        selectedFocus = focus
      case .course: break
      }
    }
  }
  private func move(_ offset: Int) {
    if let date = Clock.calendar.date(
      byAdding: weekView ? .day : .month, value: offset * (weekView ? 7 : 1), to: day)
    {
      day = date
    }
  }
}
struct FocusCorrectionView: View {
  let focus: WorkspaceItem
  var preferredIntervalID: String?
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var intervalID = ""
  @State private var start = Date()
  @State private var end = Date()
  @State private var saving = false
  @State private var error: String?
  var intervals: [WorkspaceItem] {
    session.workspace?.snapshot[.focusIntervals].filter { $0.fields.text("focus_id") == focus.id }
      .sorted { $0.fields.text("started_at") < $1.fields.text("started_at") } ?? []
  }
  var body: some View {
    NavigationStack {
      Form {
        if intervals.count > 1 {
          Picker("时段", selection: $intervalID) {
            ForEach(Array(intervals.enumerated()), id: \.element.id) { index, item in
              Text("第 \(index + 1) 段").tag(item.id)
            }
          }
        }
        WorkspaceDateTimeField(title: "开始", selection: $start, latest: .now)
        WorkspaceDateTimeField(title: "结束", selection: $end, latest: .now)
        LabeledContent("本段时长", value: "\(max(0, Int(end.timeIntervalSince(start)) / 60)) 分钟")
        if let error { Text(error).foregroundStyle(.red) }
      }.workspaceSheetForm(height: 280).navigationTitle("修正专注时间").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            saving = true
            Task {
              defer { saving = false }
              do {
                _ = try await session.workspace?.perform(
                  .correctFocus(
                    id: focus.id, intervalID: intervalID.isEmpty ? nil : intervalID, start: start,
                    end: end))
                session.scheduleSync()
                dismiss()
              } catch { self.error = error.localizedDescription }
            }
          }.disabled(saving || end <= start)
        }
      }
    }.onAppear {
      intervalID = preferredIntervalID ?? intervals.first?.id ?? ""
      load()
    }.onChange(of: intervalID) { _, _ in load() }
  }
  func load() {
    let row = intervals.first { $0.id == intervalID } ?? focus
    start = (try? Clock.parse(row.fields.text("started_at"))) ?? .now
    end = (try? Clock.parse(row.fields.text("ended_at"))) ?? .now
  }
}
