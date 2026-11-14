import SwiftUI

func timelineWeek(containing date: Date) -> [Date] {
  let calendar = Clock.calendar
  let monday = calendar.dateInterval(of: .weekOfYear, for: date)!.start
  return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
}

struct WeekTimelineDayHeading: View {
  let day: Date
  let isToday: Bool
  var body: some View {
    VStack(spacing: 3) {
      Text(day, format: .dateTime.weekday(.abbreviated)).font(.caption).foregroundStyle(.secondary)
      Text(day, format: .dateTime.day()).font(.subheadline.weight(.semibold))
        .foregroundStyle(isToday ? Color.accentColor : .primary)
    }.environment(\.timeZone, Clock.calendar.timeZone)
  }
}

/// Shared surface for the full calendar and the semester timetable.
struct WeekTimeline: View {
  private typealias Layout = WorkbenchDesign.CalendarLayout
  let days: [Date]
  let hours: ClosedRange<Int>
  var initialHour: Int? = nil
  let now: Date
  let entries: [CalendarEntry]
  let select: (CalendarEntry) -> Void

  @State private var hourHeight = Layout.timelineHourHeight
  @State private var zoomBase: CGFloat?
  @State private var zoomOffset: CGFloat = 0
  @State private var scrollOffset: CGFloat = 0
  @State private var position = ScrollPosition(y: 0)

  var body: some View {
    GeometryReader { geometry in
      let column = max(
        Layout.timelineColumnMinimum, (geometry.size.width - Layout.timelineAxisWidth) / CGFloat(days.count))
      let width = Layout.timelineAxisWidth + column * CGFloat(days.count)
      ScrollView(.horizontal) {
        VStack(spacing: 0) {
          header(column: column)
          ScrollView {
            grid(width: width, column: column)
          }
          .scrollPosition($position)
          .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            scrollOffset = y
          }
          .simultaneousGesture(zoom(viewport: geometry.size.height - Layout.timelineHeaderHeight))
        }.frame(width: width)
      }
      .overlay(alignment: .topLeading) { timeAxis }
    }
    .background(WorkbenchDesign.canvas)
    .clipShape(.rect(cornerRadius: WorkbenchDesign.radius))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchDesign.radius)
        .strokeBorder(WorkbenchDesign.line).allowsHitTesting(false)
    }
    .onChange(of: hours, initial: true) { _, range in
      position.scrollTo(y: CGFloat((initialHour ?? range.lowerBound) - range.lowerBound) * hourHeight)
    }
    .accessibilityElement(children: .contain).accessibilityIdentifier("calendar.week.timeline")
    .accessibilityValue("每小时 \(Int(hourHeight)) 点")
  }

  private func header(column: CGFloat) -> some View {
    HStack(spacing: 0) {
      Color.clear.frame(width: Layout.timelineAxisWidth)
      ForEach(days, id: \.self) { day in
        WeekTimelineDayHeading(day: day, isToday: Clock.calendar.isDate(day, inSameDayAs: now))
          .frame(width: column, height: Layout.timelineHeaderHeight)
          .background(dayTint(day))
      }
    }.frame(height: Layout.timelineHeaderHeight)
  }

  private var timeAxis: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: Layout.timelineHeaderHeight)
      GeometryReader { _ in
        ZStack(alignment: .top) {
          ForEach(hours, id: \.self) { hour in
            Text(String(format: "%02d:00", hour)).font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary).frame(width: Layout.timelineAxisWidth)
              .offset(y: CGFloat(hour - hours.lowerBound) * hourHeight + 3 - scrollOffset)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }.clipped()
    }
    .frame(width: Layout.timelineAxisWidth)
    .background(WorkbenchDesign.canvas)
    .overlay(alignment: .trailing) { Rectangle().fill(WorkbenchDesign.line).frame(width: 1) }
    .allowsHitTesting(false)
  }

  private func grid(width: CGFloat, column: CGFloat) -> some View {
    let height = CGFloat(hours.upperBound - hours.lowerBound) * hourHeight
    let byDay = Dictionary(grouping: entries) { Clock.calendar.startOfDay(for: $0.start) }
    return ZStack(alignment: .topLeading) {
      HStack(spacing: 0) {
        Color.clear.frame(width: Layout.timelineAxisWidth)
        ForEach(days, id: \.self) { day in
          dayTint(day).frame(width: column)
        }
      }.frame(height: height).accessibilityHidden(true)
      Path { path in
        for index in 0...days.count {
          let x = Layout.timelineAxisWidth + CGFloat(index) * column
          path.move(to: CGPoint(x: x, y: 0))
          path.addLine(to: CGPoint(x: x, y: height))
        }
        for hour in hours {
          let y = CGFloat(hour - hours.lowerBound) * hourHeight
          path.move(to: CGPoint(x: Layout.timelineAxisWidth, y: y))
          path.addLine(to: CGPoint(x: width, y: y))
        }
      }.stroke(WorkbenchDesign.line, lineWidth: 1).accessibilityHidden(true)
      ForEach(Array(days.enumerated()), id: \.element) { index, day in
        let x = Layout.timelineAxisWidth + CGFloat(index) * column
        let events = (byDay[day] ?? []).sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        let lanes = calendarLanes(events, minimumDuration: Double(24 / hourHeight) * 3600)
        ForEach(lanes, id: \.event.id) { lane in
          let laneWidth = column / CGFloat(lane.count)
          let y = offset(lane.event.start, from: day)
          let duration = lane.event.end.timeIntervalSince(lane.event.start) / 3600
          let blockHeight = min(max(20, duration * hourHeight - 4), height - y)
          if blockHeight > 0 {
            Button { select(lane.event) } label: {
              WeekTimelineBlock(event: lane.event, height: blockHeight)
            }.buttonStyle(.plain)
              .frame(width: max(1, laneWidth - 6), height: blockHeight).clipped()
              .offset(x: x + CGFloat(lane.lane) * laneWidth + 3, y: y + 2)
          }
        }
        let current = offset(now, from: day)
        if Clock.calendar.isDate(day, inSameDayAs: now), (0...height).contains(current) {
          Rectangle().fill(.red).frame(width: column, height: 1)
            .overlay(alignment: .leading) { Circle().fill(.red).frame(width: 5, height: 5) }
            .offset(x: x, y: current).allowsHitTesting(false).accessibilityHidden(true)
        }
      }
    }.frame(width: width, height: height + WorkbenchDesign.Space.section, alignment: .topLeading)
  }

  private func dayTint(_ day: Date) -> Color {
    if Clock.calendar.isDate(day, inSameDayAs: now) {
      return WorkbenchDesign.selectionBackground.opacity(0.6)
    }
    return Clock.calendar.isDateInWeekend(day) ? WorkbenchDesign.fieldBackground : .clear
  }

  private func offset(_ date: Date, from day: Date) -> CGFloat {
    (date.timeIntervalSince(day) / 3600 - Double(hours.lowerBound)) * hourHeight
  }

  private func zoom(viewport: CGFloat) -> some Gesture {
    MagnifyGesture().onChanged { value in
      if zoomBase == nil { zoomBase = hourHeight; zoomOffset = scrollOffset }
      let old = zoomBase ?? Layout.timelineHourHeight
      hourHeight = CalendarZoom.clamped(old * value.magnification, lower: 32, upper: 160)
      let anchor = value.startAnchor.y * max(0, viewport)
      position.scrollTo(y: max(0, (zoomOffset + anchor) * hourHeight / old - anchor))
    }.onEnded { _ in zoomBase = nil }
  }
}

private struct WeekTimelineBlock: View {
  let event: CalendarEntry
  let height: CGFloat

  private var time: String {
    TaskScheduleValues.time(event.start) + "–" + TaskScheduleValues.time(event.end)
  }

  var body: some View {
    let details = [event.room, event.inactiveLabel].compactMap { $0 }
      .filter { !$0.isEmpty }.joined(separator: " · ")
    let label = [event.title, time, details].filter { !$0.isEmpty }.joined(separator: "，")
    VStack(alignment: .leading, spacing: 3) {
      Text(event.title).font(.caption.weight(.semibold)).lineLimit(height < 44 ? 1 : 2)
      if height >= 44 {
        Text(time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
      }
      if height >= 60, !details.isEmpty {
        Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(.horizontal, 7).padding(.vertical, 4)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(event.color.opacity(0.12), in: .rect(cornerRadius: 6))
    .overlay(alignment: .leading) {
      Capsule().fill(event.color.opacity(0.7)).frame(width: 2).padding(.vertical, 4)
    }
    .contentShape(Rectangle())
    .accessibilityLabel(label)
    .help(label)
  }
}
