import SwiftUI

struct CourseCard: View {
  let item: WorkspaceItem
  let open: () -> Void
  @Environment(AppSession.self) private var session
  @State private var editCourse = false
  @State private var addMeeting = false
  @State private var editMeeting: WorkspaceItem?
  @State private var showingRemarks = false
  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }

  private var hasRemarks: Bool {
    !item[.description].string.isEmpty
      || snapshot[.attachments].contains { $0.fields["course_id"] == .string(item.id) }
  }

  var body: some View {
    let meetings = snapshot[.courseMeetings].filter { $0[.courseID].string == item.id }
      .sorted { ($0[.weekday].int, $0[.periodStart].int) < ($1[.weekday].int, $1[.periodStart].int) }
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      WorkspaceCardHeader(
        symbol: "graduationcap",
        symbolColor: courseHexColor(item[.color].string),
        title: item.title,
        subtitle: [item[.teacher].string, item[.code].string]
          .filter { !$0.isEmpty }
          .joined(separator: " · "),
        open: open,
        hasRemarks: hasRemarks,
        showingRemarks: $showingRemarks,
        menuIdentifier: "collection.menu." + item.id
      ) {
        ItemRemarks(item: item)
      } menuItems: {
        Button("编辑课程信息", systemImage: "pencil") { editCourse = true }
        Button("添加上课安排", systemImage: "calendar.badge.plus") { addMeeting = true }
      }

      CourseScheduleStatus(course: item)

      if meetings.isEmpty {
        Button("添加上课安排", systemImage: "calendar.badge.plus") { addMeeting = true }
          .buttonStyle(.borderless).font(.subheadline)
      }
      ForEach(meetings) { meeting in
        Button {
          editMeeting = meeting
        } label: {
          HStack(spacing: WorkbenchDesign.Space.small) {
            CourseMeetingSummary(
              meeting: meeting, semester: snapshot.item(.semesters, item[.semesterID].string),
              compact: true)
            Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
          }
          .frame(minHeight: WorkbenchDesign.rowMinimum)
          .contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityHint("编辑这次上课安排")
          .accessibilityIdentifier("course.meeting." + meeting.id)
          .help("编辑上课安排")
      }
      Divider().opacity(0.45)
      CollectionChecklist(item: item)
    }
    .workspaceCard().fixedSize(horizontal: false, vertical: true)
    .sheet(isPresented: $editCourse) { CourseEditor(course: item) }
    .sheet(isPresented: $addMeeting) { MeetingEditor(course: item) }
    .sheet(item: $editMeeting) { MeetingEditor(course: item, meeting: $0) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("collection.card." + item.id)
  }
}
