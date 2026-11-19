import SwiftUI

func courseHexColor(_ hex: String) -> Color {
  let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
  guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return .indigo }
  let r = Double((value >> 16) & 0xFF) / 255.0
  let g = Double((value >> 8) & 0xFF) / 255.0
  let b = Double(value & 0xFF) / 255.0
  return Color(red: r, green: g, blue: b)
}

enum CoursePalette {
  static let swatches: [(hex: String, name: String)] = [
    ("#4f7cac", "海蓝"),
    ("#2e8b7a", "青绿"),
    ("#6e5dc6", "靛紫"),
    ("#d97706", "暖橙"),
    ("#d14d72", "珊瑚"),
    ("#3b8258", "松绿"),
  ]

  static func standardPeriods(count: Int) -> [JSONValue] {
    let template: [(String, String)] = [
      ("08:00", "08:45"), ("08:55", "09:40"), ("10:00", "10:45"), ("10:55", "11:40"),
      ("14:00", "14:45"), ("14:55", "15:40"), ("16:00", "16:45"), ("16:55", "17:40"),
      ("19:00", "19:45"), ("19:55", "20:40"), ("20:50", "21:35"), ("21:45", "22:30"),
    ]
    return template.prefix(max(1, min(count, template.count))).enumerated().map { idx, pair in
      .object([
        "number": .integer(Int64(idx + 1)),
        "start": .string(pair.0),
        "end": .string(pair.1),
      ])
    }
  }

  static func snapToMonday(_ date: Date) -> Date {
    let weekday = (Clock.calendar.component(.weekday, from: date) + 5) % 7
    let startOfDay = Clock.calendar.startOfDay(for: date)
    return Clock.calendar.date(byAdding: .day, value: -weekday, to: startOfDay) ?? startOfDay
  }

  static func suggestedSemesterTitle(for date: Date = .now) -> String {
    let year = Clock.calendar.component(.year, from: date)
    let month = Clock.calendar.component(.month, from: date)
    if (2...7).contains(month) {
      return "\(year) 春季学期"
    } else if month == 1 {
      return "\(year - 1) 秋季学期"
    } else {
      return "\(year) 秋季学期"
    }
  }

  static func weekRangeSummary(_ selected: Set<Int>) -> String {
    let numbers = selected.sorted()
    guard !numbers.isEmpty else { return "未选周次" }
    var ranges: [String] = []
    var idx = 0
    while idx < numbers.count {
      let start = numbers[idx]
      var end = start
      while idx + 1 < numbers.count && numbers[idx + 1] == end + 1 {
        idx += 1
        end = numbers[idx]
      }
      ranges.append(start == end ? "\(start)" : "\(start)–\(end)")
      idx += 1
    }
    return "第 " + ranges.joined(separator: "、") + " 周"
  }
}

struct DraftMeetingSlot: Identifiable, Equatable {
  var id = UUID()
  var weekday: Int = 1
  var start: Int = 1
  var end: Int = 2
  var weeks: Set<Int>
  var room: String = ""
}

// MARK: - Shared Interactive Schedule Slot Picker

struct CourseScheduleSlotPicker: View {
  @Binding var weekday: Int
  @Binding var start: Int
  @Binding var end: Int
  @Binding var weeks: Set<Int>
  @Binding var room: String
  let term: WorkspaceItem?

  private static let dayShort = ["一", "二", "三", "四", "五", "六", "日"]
  private static let dayFull = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

  private var periods: [JSONValue] {
    (try? JSONValue(json: term?[.periods].string ?? "[]").array) ?? []
  }

  private var maxPeriod: Int {
    max(1, Int(periods.map { $0["number"].int }.max() ?? 12))
  }

  private var totalWeeks: Int {
    max(1, Int(term?[.weeks].int ?? 16))
  }

  private var timePreview: String? {
    guard
      let s = periods.first(where: { Int($0["number"].int) == start })?["start"].string,
      let e = periods.first(where: { Int($0["number"].int) == end })?["end"].string,
      !s.isEmpty, !e.isEmpty
    else { return nil }
    return "\(s)–\(e)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      // 1. Day of week pills
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("上课星期")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          if let timePreview {
            Text("\(Self.dayFull[max(0, min(6, weekday - 1))]) · \(timePreview)")
              .font(.caption.monospacedDigit().weight(.medium))
              .foregroundStyle(.tint)
          }
        }
        HStack(spacing: 6) {
          ForEach(1...7, id: \.self) { day in
            let active = weekday == day
            Button {
              weekday = day
            } label: {
              Text(Self.dayShort[day - 1])
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .white : .primary)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                  active ? Color.accentColor : WorkbenchDesign.fieldBackground,
                  in: .rect(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.dayFull[day - 1])
            .accessibilityAddTraits(active ? .isSelected : [])
          }
        }
      }

      // 2. Period range + duration quick chips
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text("节次范围")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          ForEach([2, 3, 4], id: \.self) { span in
            if start + span - 1 <= maxPeriod {
              let isCurrentSpan = (end - start + 1) == span
              Button("连上\(span)节") {
                end = min(maxPeriod, start + span - 1)
              }
              .buttonStyle(.plain)
              .font(.caption2.weight(isCurrentSpan ? .semibold : .regular))
              .foregroundStyle(isCurrentSpan ? Color.accentColor : .secondary)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(
                isCurrentSpan ? Color.accentColor.opacity(0.12) : WorkbenchDesign.fieldBackground,
                in: .capsule
              )
            }
          }
        }

        HStack(spacing: 10) {
          Picker("开始节次", selection: $start) {
            ForEach(1...maxPeriod, id: \.self) { n in
              Text(periodOptionLabel(n, isStart: true)).tag(n)
            }
          }
          .labelsHidden()

          Text("至")
            .font(.caption)
            .foregroundStyle(.secondary)

          Picker("结束节次", selection: $end) {
            ForEach(start...maxPeriod, id: \.self) { n in
              Text(periodOptionLabel(n, isStart: false)).tag(n)
            }
          }
          .labelsHidden()
        }
      }
      .onChange(of: start) { _, newStart in
        if end < newStart { end = newStart }
      }
      .onChange(of: maxPeriod) { _, cap in
        if start > cap { start = cap }
        if end > cap { end = cap }
      }

      // 3. Classroom
      TextField("上课地点 / 教室（选填，如：理教 204）", text: $room)
        .textFieldStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 8))

      // 4. Compact interactive week grid
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          Text("教学周")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(CoursePalette.weekRangeSummary(weeks))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }

        HStack(spacing: 6) {
          weekPresetButton("全部") { weeks = Set(1...totalWeeks) }
          weekPresetButton("单周") { weeks = Set((1...totalWeeks).filter { $0 % 2 == 1 }) }
          weekPresetButton("双周") { weeks = Set((1...totalWeeks).filter { $0 % 2 == 0 }) }
          if totalWeeks >= 4 {
            let half = totalWeeks / 2
            weekPresetButton("前半") { weeks = Set(1...half) }
            weekPresetButton("后半") { weeks = Set((half + 1)...totalWeeks) }
          }
          Spacer(minLength: 0)
          if !weeks.isEmpty {
            Button("清空") { weeks.removeAll() }
              .buttonStyle(.plain)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }

        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 8),
          spacing: 5
        ) {
          ForEach(1...totalWeeks, id: \.self) { w in
            let selected = weeks.contains(w)
            Button {
              if selected {
                weeks.remove(w)
              } else {
                weeks.insert(w)
              }
            } label: {
              Text("\(w)")
                .font(.caption.monospacedDigit().weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                  selected ? Color.accentColor.opacity(0.14) : WorkbenchDesign.fieldBackground,
                  in: .rect(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                  if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                      .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                  }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("第 \(w) 周")
            .accessibilityAddTraits(selected ? .isSelected : [])
          }
        }
      }
    }
  }

  private func periodOptionLabel(_ number: Int, isStart: Bool) -> String {
    let key = isStart ? "start" : "end"
    if let stamp = periods.first(where: { Int($0["number"].int) == number })?[key].string,
      !stamp.isEmpty
    {
      return "第 \(number) 节 (\(stamp))"
    }
    return "第 \(number) 节"
  }

  private func weekPresetButton(_ label: String, action: @escaping () -> Void) -> some View {
    Button(label, action: action)
      .buttonStyle(.plain)
      .font(.caption2.weight(.medium))
      .foregroundStyle(.primary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(WorkbenchDesign.fieldBackground, in: .capsule)
  }
}

// MARK: - Semester Editor

struct SemesterEditor: View {
  var semester: WorkspaceItem?
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
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
            .onChange(of: firstMonday) { _, picked in
              let snapped = CoursePalette.snapToMonday(picked)
              if snapped != picked { firstMonday = snapped }
            }
          Stepper("\(weeks) 个教学周", value: $weeks, in: 1...40)
        } footer: {
          Text("开学日期会自动对齐到当周周一（\(Clock.day(CoursePalette.snapToMonday(firstMonday)))）。")
            .font(.caption)
        }

        Section {
          ScrollView(.horizontal) {
            HStack(spacing: 8) {
              Text("一键模板：")
                .font(.caption)
                .foregroundStyle(.secondary)
              ForEach([(12, "高校 12 节"), (10, "常规 10 节"), (8, "精简 8 节")], id: \.0) { count, label in
                Button(label) {
                  periods = CoursePalette.standardPeriods(count: count)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(periods.count == count ? Color.accentColor : .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                  periods.count == count
                    ? Color.accentColor.opacity(0.12) : WorkbenchDesign.fieldBackground,
                  in: .capsule
                )
              }
            }
          }
          .scrollIndicators(.hidden)

          ForEach(periods.indices, id: \.self) { index in
            HStack(spacing: 8) {
              Text("第 \(index + 1) 节")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
              DatePicker(
                "开始", selection: periodTime(index, "start"), displayedComponents: .hourAndMinute
              ).labelsHidden()
              Text("–").foregroundStyle(.tertiary)
              DatePicker(
                "结束", selection: periodTime(index, "end"), displayedComponents: .hourAndMinute
              ).labelsHidden()
              Spacer(minLength: 0)
              if periods.count > 1 {
                Button {
                  removePeriod(at: index)
                } label: {
                  Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除此节次")
              }
            }
          }
          .onDelete { offsets in
            periods.remove(atOffsets: offsets)
            renumberPeriods()
          }

          if periods.count < 24 {
            Button("增加节次", systemImage: "plus") {
              appendNextPeriod()
            }
          }
        } header: {
          Text("作息时间（共 \(periods.count) 节）")
        }

        if let error { Text(error).foregroundStyle(.red) }
      }
      .workspaceSheetForm(height: 560)
      .navigationTitle(semester == nil ? "新建学期" : "学期设置")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            Task {
              do {
                let snappedMonday = CoursePalette.snapToMonday(firstMonday)
                let fields: [ItemField: JSONValue] = [
                  .title: .string(title.trimmingCharacters(in: .whitespacesAndNewlines)),
                  .firstMonday: .string(Clock.day(snappedMonday)),
                  .weeks: .integer(Int64(weeks)),
                  .periods: .array(periods),
                ]
                _ = try await session.workspace?.perform(
                  semester.map { .update(.semesters, id: $0.id, fields: fields) }
                    ?? .create(.semesters, fields: fields))
                session.scheduleSync()
                dismiss()
              } catch { self.error = error.localizedDescription }
            }
          }
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .onAppear {
        if let semester {
          title = semester.title
          weeks = Int(semester[.weeks].int)
          firstMonday =
            (try? Clock.parse(semester[.firstMonday].string + "T00:00:00+08:00")) ?? .now
          periods = (try? JSONValue(json: semester[.periods].string).array) ?? []
        } else {
          title = CoursePalette.suggestedSemesterTitle()
          firstMonday = CoursePalette.snapToMonday(.now)
          let inherited =
            (try? JSONValue(
              json: session.workspace?.snapshot[.semesters].last?[.periods].string ?? "[]"
            ).array) ?? []
          periods = inherited.isEmpty ? CoursePalette.standardPeriods(count: 10) : inherited
        }
      }
    }
  }

  private func removePeriod(at index: Int) {
    guard periods.indices.contains(index), periods.count > 1 else { return }
    periods.remove(at: index)
    renumberPeriods()
  }

  private func renumberPeriods() {
    for i in periods.indices {
      periods[i]["number"] = .integer(Int64(i + 1))
    }
  }

  private func appendNextPeriod() {
    let n = periods.count
    let lastEnd = periods.last.flatMap { timeMinutes($0["end"].string) } ?? (7 * 60 + 50)
    let gap = n == 4 ? 140 : (n == 8 ? 80 : 10)
    let nextStart = min(23 * 60, lastEnd + gap)
    let nextEnd = min(23 * 60 + 55, nextStart + 45)
    periods.append(
      .object([
        "number": .integer(Int64(n + 1)),
        "start": .string(String(format: "%02d:%02d", nextStart / 60, nextStart % 60)),
        "end": .string(String(format: "%02d:%02d", nextEnd / 60, nextEnd % 60)),
      ]))
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

// MARK: - Course Editor (One-Step Course + Optional Schedule Creation)

struct CourseEditor: View {
  var course: WorkspaceItem?
  var defaultSemesterID: String? = nil
  var onCreated: ((_ item: WorkspaceItem, _ scheduled: Bool) -> Void)? = nil
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var teacher = ""
  @State private var code = ""
  @State private var color = CoursePalette.swatches[0].hex
  @State private var semesterID = ""
  @State private var draftSlots: [DraftMeetingSlot] = []
  @State private var error: String?
  @State private var saving = false

  private var semesters: [WorkspaceItem] {
    (session.workspace?.snapshot[.semesters] ?? []).sorted {
      $0[.firstMonday].string > $1[.firstMonday].string
    }
  }

  private var selectedTerm: WorkspaceItem? {
    semesters.first { $0.id == semesterID }
  }

  private var canSave: Bool {
    !saving
      && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !semesterID.isEmpty
      && draftSlots.allSatisfy { !$0.weeks.isEmpty }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("基本信息") {
          TextField("课程名称", text: $title, axis: .vertical)
            .lineLimit(1...3)
          Picker("所属学期", selection: $semesterID) {
            ForEach(semesters) { Text($0.title).tag($0.id) }
          }
          TextField("授课教师（选填）", text: $teacher)
          TextField("课程代码 / 班号（选填）", text: $code)

          HStack {
            Text("课表颜色")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 8) {
              ForEach(CoursePalette.swatches, id: \.hex) { swatch in
                let isSelected = color.caseInsensitiveCompare(swatch.hex) == .orderedSame
                Button {
                  color = swatch.hex
                } label: {
                  ZStack {
                    Circle()
                      .fill(courseHexColor(swatch.hex))
                      .frame(width: 20, height: 20)
                    if isSelected {
                      Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                      Circle()
                        .strokeBorder(courseHexColor(swatch.hex), lineWidth: 1.8)
                        .frame(width: 26, height: 26)
                    }
                  }
                  .frame(width: 28, height: 28)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("颜色 " + swatch.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
              }
            }
          }
        }

        if course == nil {
          Section {
            ForEach($draftSlots) { $slot in
              VStack(alignment: .leading, spacing: 10) {
                HStack {
                  Text("时段 \((draftSlots.firstIndex(where: { $0.id == slot.id }) ?? 0) + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                  Spacer()
                  Button(role: .destructive) {
                    draftSlots.removeAll { $0.id == slot.id }
                  } label: {
                    Label("移除", systemImage: "trash")
                      .font(.caption)
                  }
                  .buttonStyle(.plain)
                  .foregroundStyle(.red)
                }
                CourseScheduleSlotPicker(
                  weekday: $slot.weekday,
                  start: $slot.start,
                  end: $slot.end,
                  weeks: $slot.weeks,
                  room: $slot.room,
                  term: selectedTerm
                )
              }
              .padding(.vertical, 4)
            }

            Button {
              addDraftSlot()
            } label: {
              Label(
                draftSlots.isEmpty ? "同时添加上课时间与教室" : "再添加一个上课时段",
                systemImage: "calendar.badge.plus"
              )
            }
          } header: {
            Text("上课时间（选填，也可保存后再设）")
          }
        }

        if let error { Text(error).foregroundStyle(.red) }
      }
      .workspaceSheetForm(height: draftSlots.isEmpty ? 360 : 580)
      .navigationTitle(course == nil ? "添加课程" : "课程信息")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存", action: save)
            .disabled(!canSave)
        }
      }
      .onAppear {
        if let course {
          title = course.title
          teacher = course[.teacher].string
          code = course[.code].string
          let savedColor = course[.color].string
          color = savedColor.isEmpty ? CoursePalette.swatches[0].hex : savedColor
          semesterID = course[.semesterID].string
        } else {
          let resolvedID =
            (defaultSemesterID?.isEmpty == false ? defaultSemesterID : nil)
            ?? semesters.first?.id ?? ""
          semesterID = resolvedID
          let existingCount = (session.workspace?.snapshot[.courses] ?? []).count
          color = CoursePalette.swatches[existingCount % CoursePalette.swatches.count].hex
        }
      }
      .onChange(of: semesterID) { _, _ in
        clampDraftSlotsToTerm()
      }
    }
  }

  private func addDraftSlot() {
    let totalWeeks = max(1, Int(selectedTerm?[.weeks].int ?? 16))
    let periods = (try? JSONValue(json: selectedTerm?[.periods].string ?? "[]").array) ?? []
    let maxP = max(1, Int(periods.map { $0["number"].int }.max() ?? 1))
    let nextDay = min(7, (draftSlots.last?.weekday ?? 0) + 1)
    draftSlots.append(
      DraftMeetingSlot(
        weekday: nextDay,
        start: 1,
        end: min(maxP, 2),
        weeks: Set(1...totalWeeks),
        room: draftSlots.last?.room ?? ""
      )
    )
  }

  private func clampDraftSlotsToTerm() {
    let totalWeeks = max(1, Int(selectedTerm?[.weeks].int ?? 16))
    let periods = (try? JSONValue(json: selectedTerm?[.periods].string ?? "[]").array) ?? []
    let maxP = max(1, Int(periods.map { $0["number"].int }.max() ?? 1))
    for i in draftSlots.indices {
      draftSlots[i].weeks = draftSlots[i].weeks.filter { (1...totalWeeks).contains($0) }
      if draftSlots[i].weeks.isEmpty { draftSlots[i].weeks = Set(1...totalWeeks) }
      if draftSlots[i].start > maxP { draftSlots[i].start = maxP }
      if draftSlots[i].end > maxP { draftSlots[i].end = maxP }
    }
  }

  private func save() {
    guard canSave, let store = session.workspace else { return }
    saving = true
    Task {
      defer { saving = false }
      do {
        let fields: [ItemField: JSONValue] = [
          .title: .string(title.trimmingCharacters(in: .whitespacesAndNewlines)),
          .teacher: .string(teacher.trimmingCharacters(in: .whitespacesAndNewlines)),
          .code: .string(code.trimmingCharacters(in: .whitespacesAndNewlines)),
          .color: .string(color),
          .semesterID: .string(semesterID),
        ]
        let result = try await store.perform(
          course.map { .update(.courses, id: $0.id, fields: fields) }
            ?? .create(.courses, fields: fields))
        if course == nil, let id = result.id {
          for slot in draftSlots {
            let meetingFields: [ItemField: JSONValue] = [
              .courseID: .string(id),
              .weekday: .integer(Int64(slot.weekday)),
              .periodStart: .integer(Int64(slot.start)),
              .periodEnd: .integer(Int64(slot.end)),
              .weeks: .array(slot.weeks.sorted().map { .integer(Int64($0)) }),
              .room: .string(slot.room.trimmingCharacters(in: .whitespacesAndNewlines)),
            ]
            _ = try await store.perform(.create(.courseMeetings, fields: meetingFields))
          }
          if let item = store.snapshot.item(.courses, id) {
            onCreated?(item, !draftSlots.isEmpty)
          }
        }
        session.scheduleSync()
        dismiss()
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}

// MARK: - Meeting Editor

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
  @State private var confirmingDelete = false
  @State private var error: String?

  var term: WorkspaceItem? {
    session.workspace?.snapshot.item(.semesters, course[.semesterID].string)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          CourseScheduleSlotPicker(
            weekday: $weekday,
            start: $start,
            end: $end,
            weeks: $weeks,
            room: $room,
            term: term
          )
          .padding(.vertical, 4)
        } header: {
          Text(course.title)
        }

        if meeting != nil {
          Section {
            Button("删除此次上课安排", systemImage: "trash", role: .destructive) {
              confirmingDelete = true
            }
          }
        }

        if let error { Text(error).foregroundStyle(.red) }
      }
      .workspaceSheetForm(height: 520)
      .navigationTitle(meeting == nil ? "添加上课安排" : "编辑上课安排")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            Task {
              do {
                let fields: [ItemField: JSONValue] = [
                  .courseID: .string(course.id),
                  .weekday: .integer(Int64(weekday)),
                  .periodStart: .integer(Int64(start)),
                  .periodEnd: .integer(Int64(end)),
                  .weeks: .array(weeks.sorted().map { .integer(Int64($0)) }),
                  .room: .string(room.trimmingCharacters(in: .whitespacesAndNewlines)),
                ]
                _ = try await session.workspace?.perform(
                  meeting.map { .update(.courseMeetings, id: $0.id, fields: fields) }
                    ?? .create(.courseMeetings, fields: fields))
                session.scheduleSync()
                dismiss()
              } catch { self.error = error.localizedDescription }
            }
          }
          .disabled(weeks.isEmpty)
        }
      }
      .confirmationDialog("删除此次上课安排？", isPresented: $confirmingDelete, titleVisibility: .visible) {
        if let meeting {
          Button("删除", role: .destructive) {
            session.run {
              _ = try await session.workspace?.perform(.delete(.courseMeetings, id: meeting.id))
              dismiss()
            }
          }
        }
      }
      .onAppear {
        let periods = (try? JSONValue(json: term?[.periods].string ?? "[]").array) ?? []
        let maxP = max(1, Int(periods.map { $0["number"].int }.max() ?? 1))
        if let meeting {
          weekday = Int(meeting[.weekday].int)
          start = min(maxP, max(1, Int(meeting[.periodStart].int)))
          end = min(maxP, max(start, Int(meeting[.periodEnd].int)))
          weeks = Set(
            (try? JSONValue(json: meeting[.weeks].string).array.map { Int($0.int) }) ?? [])
          room = meeting[.room].string
        } else {
          let firstNum = Int(periods.first?["number"].int ?? 1)
          start = firstNum
          end = min(maxP, firstNum + 1)
          weeks = Set(1...max(1, Int(term?[.weeks].int ?? 16)))
        }
      }
    }
  }
}

// MARK: - Semester Management

struct SemesterManagementView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var adding = false
  @State private var editing: WorkspaceItem?
  @State private var deleting: WorkspaceItem?

  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var semesters: [WorkspaceItem] {
    snapshot[.semesters].sorted { $0[.firstMonday].string > $1[.firstMonday].string }
  }

  private func courseCount(for term: WorkspaceItem) -> Int {
    snapshot[.courses].filter { $0[.semesterID].string == term.id }.count
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button("新建学期", systemImage: "plus") { adding = true }
        }
        Section("全部学期") {
          ForEach(semesters) { term in
            let count = courseCount(for: term)
            HStack {
              Button {
                editing = term
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(term.title).foregroundStyle(.primary)
                    Text("\(term[.firstMonday].string) 开学 · \(term[.weeks].int) 周 · \(count) 门课程")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)

              Button {
                deleting = term
              } label: {
                Image(systemName: "trash")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .help("删除学期")
            }
          }
        }
      }
      .workspaceSettingsForm()
      .navigationTitle("学期管理")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
      }
      .sheet(isPresented: $adding) { SemesterEditor() }
      .sheet(item: $editing) { SemesterEditor(semester: $0) }
      .confirmationDialog(
        "删除学期「\(deleting?.title ?? "")」？",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible
      ) {
        if let target = deleting {
          Button("删除学期及下属课程", role: .destructive) {
            deleting = nil
            session.run {
              _ = try await session.workspace?.perform(.delete(.semesters, id: target.id))
            }
          }
        }
      } message: {
        if let target = deleting {
          let c = courseCount(for: target)
          Text(c > 0 ? "该学期下的 \(c) 门课程及排课安排也会一并移除。" : "确定移除这个空学期吗？")
        }
      }
    }
  }
}
