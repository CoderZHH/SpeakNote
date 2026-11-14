import SwiftUI

struct CourseCard: View {
  let item: WorkspaceItem
  let open: () -> Void
  @Environment(AppSession.self) private var session
  @State private var editCourse = false
  @State private var addMeeting = false
  @State private var editMeeting: WorkspaceItem?
  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }

  var body: some View {
    let meetings = snapshot[.courseMeetings].filter { $0[.courseID].string == item.id }
      .sorted { ($0[.weekday].int, $0[.periodStart].int) < ($1[.weekday].int, $1[.periodStart].int) }
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
      header
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
      Divider()
      CollectionChecklist(item: item)
    }
    .workspaceCard().fixedSize(horizontal: false, vertical: true)
    .sheet(isPresented: $editCourse) { CourseEditor(course: item) }
    .sheet(isPresented: $addMeeting) { MeetingEditor(course: item) }
    .sheet(item: $editMeeting) { MeetingEditor(course: item, meeting: $0) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("collection.card." + item.id)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: WorkbenchDesign.Space.small) {
      Button(action: open) {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchDesign.Space.small) {
          Image(systemName: "graduationcap").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            if !item[.teacher].string.isEmpty {
              Text(item[.teacher].string).font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
        }
        .frame(minHeight: WorkbenchDesign.rowMinimum)
        .contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityHint("打开课程详情")
      WorkspaceMoreMenu {
        Button("编辑课程信息", systemImage: "pencil") { editCourse = true }
        Button("添加上课安排", systemImage: "calendar.badge.plus") { addMeeting = true }
      }
        .accessibilityIdentifier("collection.menu." + item.id)
    }
  }
}
