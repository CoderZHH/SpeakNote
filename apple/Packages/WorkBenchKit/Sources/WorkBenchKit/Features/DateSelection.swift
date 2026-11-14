import SwiftUI

/// One date surface for schedules, deadlines, semesters and history correction.
struct WorkspaceDateField: View {
  let title: String
  @Binding var selection: Date
  var latest: Date = .distantFuture
  @State private var showing = false
  var body: some View {
    LabeledContent(title) {
      Button { showing = true } label: {
        Label(selection.formatted(.dateTime.year().month().day()), systemImage: "calendar")
          .font(.subheadline).padding(.horizontal, 10).padding(.vertical, 7)
          .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 8))
      }.buttonStyle(.plain).accessibilityIdentifier("date.selection." + title).popover(isPresented: $showing) {
        VStack(spacing: WorkbenchDesign.Space.medium) {
          DatePicker(title, selection: $selection, in: ...latest, displayedComponents: .date)
            .datePickerStyle(.graphical).labelsHidden().controlSize(.large)
          HStack {
            Button("今天") { selection = min(.now, latest) }
            Spacer()
            Button("完成") { showing = false }.keyboardShortcut(.defaultAction)
          }
        }.padding(WorkbenchDesign.Space.section).frame(width: 320)
          .presentationCompactAdaptation(.popover)
      }
    }.environment(\.calendar, Clock.calendar).environment(\.timeZone, Clock.calendar.timeZone)
  }
}
struct WorkspaceDateTimeField: View {
  let title: String
  @Binding var selection: Date
  var latest: Date = .distantFuture
  var body: some View {
    VStack(spacing: WorkbenchDesign.Space.small) {
      WorkspaceDateField(title: title, selection: $selection, latest: latest)
      DatePicker("时间", selection: $selection, in: ...latest, displayedComponents: .hourAndMinute)
    }
  }
}

enum CalendarZoom {
  static func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    guard value.isFinite else { return lower }
    return min(upper, max(lower, value))
  }
}
