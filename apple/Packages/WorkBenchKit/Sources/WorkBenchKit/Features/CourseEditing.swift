import SwiftUI

struct SemesterEditor: View {
  var semester: WorkspaceItem?
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var title = "新学期"
  @State private var firstMonday = Date()
  @State private var weeks = 16
  @State private var periods: [JSONValue] = []
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("学期名称", text: $title)
          WorkspaceDateField(title: "第一周周一", selection: $firstMonday)
          Stepper("\(weeks) 个教学周", value: $weeks, in: 1...40)
        }
        Section("作息时间") {
          ForEach(periods.indices, id: \.self) { index in
            HStack {
              Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
              DatePicker(
                "开始", selection: periodTime(index, "start"), displayedComponents: .hourAndMinute
              ).labelsHidden()
              Text("–").foregroundStyle(.tertiary)
              DatePicker(
                "结束", selection: periodTime(index, "end"), displayedComponents: .hourAndMinute
              ).labelsHidden()
            }
          }.onDelete {
            periods.remove(atOffsets: $0)
            for i in periods.indices { periods[i]["number"] = .integer(Int64(i + 1)) }
          }
          if periods.count < 24 {
            Button("增加节次", systemImage: "plus") {
              let n = periods.count
              let hour = min(22, 8 + n)
              periods.append(
                .object([
                  "number": .integer(Int64(n + 1)),
                  "start": .string(String(format: "%02d:00", hour)),
                  "end": .string(String(format: "%02d:45", hour)),
                ]))
            }
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.workspaceSheetForm(height: 540).navigationTitle(semester == nil ? "新建学期" : "学期设置").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            Task {
              do {
                let fields: [ItemField: JSONValue] = [
                  .title: .string(title), .firstMonday: .string(Clock.day(firstMonday)),
                  .weeks: .integer(Int64(weeks)), .periods: .array(periods),
                ]
                _ = try await session.workspace?.perform(
                  semester.map { .update(.semesters, id: $0.id, fields: fields) }
                    ?? .create(.semesters, fields: fields))
                session.scheduleSync()
                dismiss()
              } catch { self.error = error.localizedDescription }
            }
          }
        }
      }.onAppear {
        if let semester {
          title = semester.title
          weeks = Int(semester[.weeks].int)
          firstMonday =
            (try? Clock.parse(semester[.firstMonday].string + "T00:00:00+08:00")) ?? .now
          periods = (try? JSONValue(json: semester[.periods].string).array) ?? []
        } else {
          let weekday = (Clock.calendar.component(.weekday, from: .now) + 5) % 7
          firstMonday = Clock.calendar.date(byAdding: .day, value: -weekday, to: .now)!
          periods = (try? JSONValue(json: session.workspace?.snapshot[.semesters].last?[.periods].string ?? "[]").array) ?? []
          if periods.isEmpty {
            periods = [.object(["number": .integer(1), "start": .string("08:00"), "end": .string("08:45")])]
          }
        }
      }
    }
  }
  func periodTime(_ index: Int, _ field: String) -> Binding<Date> {
    Binding(
      get: {
        (try? Clock.parse("2026-01-01T" + periods[index][field].string + ":00+08:00")) ?? .now
      },
      set: { date in
        let c = Clock.calendar.dateComponents([.hour, .minute], from: date)
        periods[index][field] = .string(String(format: "%02d:%02d", c.hour!, c.minute!))
      })
  }
}
struct CourseEditor: View {
  var course: WorkspaceItem?
  var defaultSemesterID: String? = nil
  var onCreated: ((WorkspaceItem) -> Void)? = nil
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var teacher = ""
  @State private var code = ""
  @State private var semesterID = ""
  @State private var error: String?
  @State private var saving = false
  var body: some View {
    NavigationStack {
      Form {
        TextField("课程名称", text: $title, axis: .vertical).lineLimit(1...4)
        Picker("学期", selection: $semesterID) {
          ForEach(session.workspace?.snapshot[.semesters] ?? []) { Text($0.title).tag($0.id) }
        }
        TextField("教师", text: $teacher)
        TextField("课程班号", text: $code)
        if let error { Text(error).foregroundStyle(.red) }
      }.workspaceSheetForm(height: 300).navigationTitle(course == nil ? "添加课程" : "课程信息").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            guard !saving, let store = session.workspace else { return }
            saving = true
            Task {
              defer { saving = false }
              do {
                let fields: [ItemField: JSONValue] = [
                  .title: .string(title), .teacher: .string(teacher), .code: .string(code),
                  .semesterID: .string(semesterID),
                ]
                let result = try await store.perform(
                  course.map { .update(.courses, id: $0.id, fields: fields) }
                    ?? .create(.courses, fields: fields))
                if course == nil, let id = result.id, let item = store.snapshot.item(.courses, id) {
                  onCreated?(item)
                }
                session.scheduleSync()
                dismiss()
              } catch { self.error = error.localizedDescription }
            }
          }.disabled(
            saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || semesterID.isEmpty)
        }
      }.onAppear {
        if let course {
          title = course.title
          teacher = course[.teacher].string
          code = course[.code].string
          semesterID = course[.semesterID].string
        } else {
          semesterID = defaultSemesterID ?? session.workspace?.snapshot[.semesters].last?.id ?? ""
        }
      }
    }
  }
}
struct MeetingEditor: View {
  let course: WorkspaceItem
  var meeting: WorkspaceItem?
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var weekday = 1
  @State private var start = 1
  @State private var end = 2
  @State private var weeks: Set<Int> = []
  @State private var room = ""
  @State private var error: String?
  var term: WorkspaceItem? {
    session.workspace?.snapshot.item(.semesters, course[.semesterID].string)
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("星期", selection: $weekday) {
            ForEach(1...7, id: \.self) {
              Text(["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"][$0]).tag($0)
            }
          }
          Stepper("开始 · 第 \(start) 节", value: $start, in: 1...24)
          Stepper("结束 · 第 \(end) 节", value: $end, in: start...max(start, 24))
          TextField("教室", text: $room)
        }
        Section("教学周") {
          HStack {
            Button("全选") { weeks = Set(1...max(1, Int(term?[.weeks].int ?? 16))) }
            Spacer()
            Button("单周") {
              weeks = Set((1...max(1, Int(term?[.weeks].int ?? 16))).filter { $0 % 2 == 1 })
            }
            Button("双周") {
              weeks = Set((1...max(1, Int(term?[.weeks].int ?? 16))).filter { $0 % 2 == 0 })
            }
          }
          ForEach(1...max(1, Int(term?[.weeks].int ?? 16)), id: \.self) { week in
            Toggle(
              "第 \(week) 周",
              isOn: Binding(
                get: { weeks.contains(week) },
                set: { value in if value { weeks.insert(week) } else { weeks.remove(week) } }))
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.workspaceSheetForm(height: 540).navigationTitle("上课安排").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            Task {
              do {
                let fields: [ItemField: JSONValue] = [
                  .courseID: .string(course.id), .weekday: .integer(Int64(weekday)),
                  .periodStart: .integer(Int64(start)), .periodEnd: .integer(Int64(end)),
                  .weeks: .array(weeks.sorted().map { .integer(Int64($0)) }), .room: .string(room),
                ]
                _ = try await session.workspace?.perform(
                  meeting.map { .update(.courseMeetings, id: $0.id, fields: fields) }
                    ?? .create(.courseMeetings, fields: fields))
                session.scheduleSync()
                dismiss()
              } catch { self.error = error.localizedDescription }
            }
          }.disabled(weeks.isEmpty)
        }
      }.onChange(of: start) { _, value in end = max(value, end) }.onAppear {
        if let meeting {
          weekday = Int(meeting[.weekday].int)
          start = Int(meeting[.periodStart].int)
          end = Int(meeting[.periodEnd].int)
          weeks = Set(
            (try? JSONValue(json: meeting[.weeks].string).array.map { Int($0.int) }) ?? [])
          room = meeting[.room].string
        } else {
          let periods = (try? JSONValue(json: term?[.periods].string ?? "[]").array) ?? []
          start = Int(periods.first?["number"].int ?? 1)
          end = start
          weeks = Set(1...max(1, Int(term?[.weeks].int ?? 16)))
        }
      }
    }
  }
}

struct SemesterManagementView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var adding = false
  @State private var editing: WorkspaceItem?
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button("新建学期", systemImage: "plus") { adding = true }
        }
        Section("学期") {
          ForEach(session.workspace?.snapshot[.semesters] ?? []) { term in
            Button { editing = term } label: {
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  Text(term.title).foregroundStyle(.primary)
                  Text(term[.firstMonday].string + " · " + String(term[.weeks].int) + " 周")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
              }
            }.buttonStyle(.plain)
          }
        }
      }.workspaceSettingsForm().navigationTitle("学期管理").toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
      }
      .sheet(isPresented: $adding) { SemesterEditor() }
      .sheet(item: $editing) { SemesterEditor(semester: $0) }
    }
  }
}
