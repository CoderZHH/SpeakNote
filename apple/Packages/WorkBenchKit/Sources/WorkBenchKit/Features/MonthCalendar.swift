import SwiftUI

/// The same Monday-first, Shanghai calendar drives the weekday header and every cell.
struct CalendarMonth {
  let start: Date
  let days: [Date]
  init(_ date: Date) {
    let calendar = Clock.calendar
    start = calendar.dateInterval(of: .month, for: date)!.start
    let count = calendar.range(of: .day, in: .month, for: start)!.count
    let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
    let first = calendar.date(byAdding: .day, value: -leading, to: start)!
    let cells = ((leading + count + 6) / 7) * 7
    days = (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
  }
  func contains(_ day: Date) -> Bool {
    Clock.calendar.isDate(day, equalTo: start, toGranularity: .month)
  }
}

struct CalendarDayContent {
  let entries: [CalendarEntry]
  let untimedTasks: [WorkspaceItem]
  init(snapshot: WorkspaceSnapshot, day: Date, now: Date) {
    entries = calendarEntries(snapshot: snapshot, day: day, now: now)
    untimedTasks = snapshot[.tasks].filter {
      $0.status == "todo" && $0[.plannedDate].string == Clock.day(day) && $0[.startTime].isNull
    }.sorted { ($0.importance, $0.createdAt) > ($1.importance, $1.createdAt) }
  }
  var isEmpty: Bool { entries.isEmpty && untimedTasks.isEmpty }
}

struct MonthCalendar: View {
  @Binding var day: Date
  let snapshot: WorkspaceSnapshot
  let now: Date
  let expanded: Bool
  @State private var scale: CGFloat = 1
  @State private var baseScale: CGFloat?
  @State private var offset = CGPoint.zero
  @State private var baseOffset = CGPoint.zero
  @State private var position = ScrollPosition(x: 0, y: 0)
  private var month: CalendarMonth { CalendarMonth(day) }
  var body: some View {
    GeometryReader { geometry in
      ScrollView([.horizontal, .vertical]) {
        grid(width: geometry.size.width * scale, height: geometry.size.height * scale)
      }.scrollPosition($position)
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, p in offset = p }
        .simultaneousGesture(MagnifyGesture().onChanged { value in
          if baseScale == nil { baseScale = scale; baseOffset = offset }
          let old = baseScale ?? 1
          scale = CalendarZoom.clamped(old * value.magnification, lower: 1, upper: 3)
          let x = value.startAnchor.x * geometry.size.width
          let y = value.startAnchor.y * geometry.size.height
          position.scrollTo(point: CGPoint(x: max(0, (baseOffset.x + x) * scale / old - x),
            y: max(0, (baseOffset.y + y) * scale / old - y)))
        }.onEnded { _ in baseScale = nil })
    }.accessibilityElement(children: .contain).accessibilityIdentifier("calendar.month.grid")
      .accessibilityValue("缩放 \(Int(scale * 100))%")
  }
  private func grid(width: CGFloat, height: CGFloat) -> some View {
      let column = width / 7
      let row = max(
        0,
        (height - WorkbenchDesign.CalendarLayout.weekdayHeight)
          / CGFloat(month.days.count / 7))
      let previews = max(
        0,
        min(
          12,
          Int(
            (row - WorkbenchDesign.CalendarLayout.dayHeight)
              / WorkbenchDesign.CalendarLayout.previewHeight)))
      return VStack(spacing: 0) {
        HStack(spacing: 0) {
          ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) {
            index, title in
            Text(title).font(.caption).foregroundStyle(index >= 5 ? .tertiary : .secondary)
              .frame(width: column, height: WorkbenchDesign.CalendarLayout.weekdayHeight)
          }
        }
        ForEach(0..<(month.days.count / 7), id: \.self) { week in
          HStack(spacing: 0) {
            ForEach(Array(month.days[(week * 7)..<(week * 7 + 7)]), id: \.self) { date in
              cell(date, previews: previews).frame(width: column, height: row).clipped()
            }
          }
        }
      }
      .frame(width: width, height: height)
  }
  private func cell(_ date: Date, previews: Int) -> some View {
    let content = CalendarDayContent(snapshot: snapshot, day: date, now: now)
    let selected = Clock.day(date) == Clock.day(day)
    let today = Clock.day(date) == Clock.day(now)
    return Button {
      day = date
    } label: {
      VStack(alignment: (expanded || scale > 1.15) ? .leading : .center, spacing: 3) {
        Text("\(Clock.calendar.component(.day, from: date))").monospacedDigit().lineLimit(1).font(
          .body.weight(selected || today ? .semibold : .regular)
        )
        .foregroundStyle(
          selected
            ? Color.white
            : today
              ? Color.accentColor
              : month.contains(date) ? Color.primary : Color.secondary.opacity(0.5)
        )
        .frame(
          width: WorkbenchDesign.CalendarLayout.dateDiameter,
          height: WorkbenchDesign.CalendarLayout.dateDiameter
        )
        .background(selected ? Color.accentColor : .clear, in: Circle())
        if expanded || scale > 1.15 {
          let titles =
            content.untimedTasks.map { ($0.id, $0.title, Color.blue) }
            + content.entries.map { ($0.id, $0.displayTitle, $0.color) }
          ForEach(
            Array(titles.prefix(titles.count > previews && previews > 1 ? previews - 1 : previews)),
            id: \.0
          ) { _, title, color in
            Text(title).font(.caption).lineLimit(1).foregroundStyle(color)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if titles.count > previews && previews > 1 {
            Text("还有 \(titles.count - previews + 1) 项").font(.caption2).foregroundStyle(.secondary)
          } else if previews == 0 {
            Circle().fill(content.isEmpty ? Color.clear : Color.accentColor).frame(
              width: 4, height: 4)
          }
          Spacer(minLength: 0)
        } else {
          Circle().fill(content.isEmpty ? Color.clear : Color.accentColor)
            .frame(width: 4, height: 4)
        }
      }.padding((expanded || scale > 1.15) ? WorkbenchDesign.Space.small : 0)
        .frame(
          maxWidth: .infinity, maxHeight: .infinity, alignment: (expanded || scale > 1.15) ? .topLeading : .center
        )
        .background(selected && (expanded || scale > 1.15) ? WorkbenchDesign.selectionBackground : .clear)
        .overlay(alignment: .top) {
          if expanded || scale > 1.15 { Rectangle().fill(WorkbenchDesign.line).frame(height: 1) }
        }
        .overlay(alignment: .leading) {
          if expanded || scale > 1.15 { Rectangle().fill(WorkbenchDesign.line).frame(width: 1) }
        }
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .accessibilityLabel(date.formatted(.dateTime.year().month().day().weekday()))
      .accessibilityValue(
        content.isEmpty ? "无日程" : "\(content.entries.count + content.untimedTasks.count) 项日程"
      )
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityIdentifier("calendar.day." + Clock.day(date))
  }
}

struct CalendarDayAgenda: View {
  let day: Date
  let snapshot: WorkspaceSnapshot
  let now: Date
  let select: (CalendarEntry) -> Void
  private var content: CalendarDayContent { .init(snapshot: snapshot, day: day, now: now) }
  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      Text(day, format: .dateTime.month().day().weekday(.wide)).font(.headline)
        .accessibilityIdentifier("calendar.agenda.heading")
      if content.isEmpty {
        Label("当天没有日程", systemImage: "calendar.badge.clock").font(.subheadline)
          .foregroundStyle(.secondary).padding(.vertical, WorkbenchDesign.Space.section)
          .accessibilityIdentifier("calendar.agenda.empty")
        Spacer(minLength: 0)
      } else {
        WorkspaceList(inset: 0) {
          if !content.untimedTasks.isEmpty {
            Section("全天") {
              ForEach(content.untimedTasks) { ItemRow(item: $0) }
            }
          }
          ForEach(content.entries) { entry in
            if case .course(let course) = entry.kind {
              NavigationLink(value: CollectionRoute(entity: .courses, id: course.id)) {
                entryRow(entry)
              }
            } else {
              Button {
                select(entry)
              } label: {
                entryRow(entry)
              }.buttonStyle(.plain)
            }
          }
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private func entryRow(_ entry: CalendarEntry) -> some View {
    HStack(alignment: .top, spacing: WorkbenchDesign.Space.small) {
      Image(systemName: symbol(entry)).foregroundStyle(entry.color).frame(width: 18)
      VStack(alignment: .leading, spacing: 5) {
        Text(entry.displayTitle).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 5) {
          Text(entry.start, format: .dateTime.hour().minute())
          Text("–")
          Text(entry.end, format: .dateTime.hour().minute())
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if case .focus = entry.kind {
        Image(systemName: "slider.horizontal.3").foregroundStyle(.tertiary)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, WorkbenchDesign.rowInset)
  }
  private func symbol(_ entry: CalendarEntry) -> String {
    switch entry.kind {
    case .task: "circle"
    case .focus: "timer"
    case .completed: "checkmark.circle"
    case .course: "graduationcap"
    }
  }
}
