import SwiftUI

struct ThoughtRoute: Hashable, Identifiable {
  let id: String
  var initialTags: [String]? = nil
}
struct ThoughtSummary: View {
  let item: WorkspaceItem
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: WorkbenchDesign.Space.small) {
      let title = thoughtTitle(item[.content].string)
      let tags = thoughtTags(item).map { "#" + $0 }.joined(separator: " ")
      Text(
        "\(Text(title).font(.body.weight(.medium)))\(Text(tags.isEmpty ? "" : "  " + tags).font(.caption).foregroundColor(.secondary))"
      ).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      Text(String(item[.day].string.suffix(5)).replacingOccurrences(of: "-", with: "/"))
        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
    }.padding(.vertical, WorkbenchDesign.Space.small).contentShape(Rectangle())
  }
}
struct ThoughtsView: View {
  @Environment(AppSession.self) private var session
  @State private var tag = "全部"
  @State private var managingTags = false
  @State private var tagToRemove: String?
  @State private var search = ""
  @State private var selected: String?
  @State private var composition: ThoughtRoute?
  @State private var newRoute: ThoughtRoute?
  private var allThoughts: [WorkspaceItem] {
    let saved = session.workspace?.snapshot[.reflections] ?? []
    let ids = Set(saved.map(\.id))
    return saved + session.thoughtEditing.pendingItems.filter { !ids.contains($0.id) }
  }
  private var tags: [String] {
    ["全部"] + Set(allThoughts.flatMap { item in
      session.thoughtEditing.buffers[item.id]?.tags ?? thoughtTags(item)
    }).subtracting(["全部"]).sorted()
  }
  private var thoughts: [WorkspaceItem] {
    allThoughts.filter {
      (tag == "全部" || thoughtTags($0).contains(tag))
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
          || thoughtTags($0).contains { $0.localizedCaseInsensitiveContains(search) })
    }.sorted { ($0[.day].string, $0.createdAt, $0.id) > ($1[.day].string, $1.createdAt, $1.id) }
  }
  var body: some View {
    Group {
      #if os(macOS)
        GeometryReader { geometry in
          if geometry.size.width >= 740 {
            HSplitView {
              browser(selection: true).frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
              Group {
                if let selected,
                  let route = editorRoute(selected)
                {
                  ThoughtEditor(id: route.id, initialTags: route.initialTags).id(route.id)
                } else {
                  ContentUnavailableView("选择一篇思考", systemImage: "text.bubble")
                }
              }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar { newButton(inline: true) }
          } else {
            browser(selection: false).toolbar { newButton(inline: false) }
          }
        }
      #else
        browser(selection: false).phoneCreateAction("记一点", identifier: "thought.new") {
          beginNew(inline: false)
        }
      #endif
    }
    .alert("删除标签？", isPresented: Binding(
      get: { tagToRemove != nil }, set: { if !$0 { tagToRemove = nil } }
    ), presenting: tagToRemove) { name in
      Button("删除", role: .destructive) {
        session.run {
          guard let store = session.workspace else { return }
          try await session.thoughtEditing.removeTag(name, from: store)
          if tag == name { tag = "全部" }
        }
      }
      Button("取消", role: .cancel) {}
    } message: { name in
      Text("「\(name)」将从所有思考中移除，正文会保留。")
    }
    .onChange(of: tags) { _, available in
      if !available.contains(tag) { tag = "全部" }
    }
    .navigationDestination(for: ThoughtRoute.self) {
      ThoughtEditor(id: $0.id, initialTags: $0.initialTags)
    }
    .navigationDestination(item: $newRoute) {
      ThoughtEditor(id: $0.id, initialTags: $0.initialTags)
    }
    #if os(macOS)
      .onChange(of: thoughts.map(\.id), initial: true) { _, ids in
        if selected == nil {
          selected = ids.first
        } else if let selected, editorRoute(selected) == nil {
          self.selected = ids.first
        }
      }
    #endif
  }
  @ToolbarContentBuilder private func newButton(inline: Bool) -> some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button("记一点", systemImage: "square.and.pencil") {
        beginNew(inline: inline)
      }.accessibilityIdentifier("thought.new")
    }
  }
  private func beginNew(inline: Bool) {
    let route = ThoughtRoute(
      id: UUID().uuidString.lowercased(),
      initialTags: tag == "全部" ? [] : [tag])
    session.thoughtEditing.beginNew(id: route.id, tags: route.initialTags ?? [])
    if inline {
      composition = route
      selected = route.id
    } else {
      newRoute = route
    }
  }
  private func editorRoute(_ id: String) -> ThoughtRoute? {
    if composition?.id == id { return composition }
    if allThoughts.contains(where: { $0.id == id }) { return ThoughtRoute(id: id) }
    return nil
  }
  private var tagManagement: some View {
      VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
        Text("管理标签").font(.headline)
        if tags.count == 1 {
          Text("还没有标签").foregroundStyle(.secondary)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
              ForEach(tags.dropFirst(), id: \.self) { name in
                HStack {
                  Text(name)
                  Spacer()
                  Button("删除标签", systemImage: "trash", role: .destructive) {
                    managingTags = false
                    tagToRemove = name
                  }
                  .labelStyle(.iconOnly)
                  .accessibilityLabel("删除标签 " + name)
                }
              }
            }
          }.frame(maxHeight: WorkbenchDesign.ThoughtLayout.tagListHeight)
        }
      }
      .padding(WorkbenchDesign.Space.section)
      .frame(width: WorkbenchDesign.ThoughtLayout.tagPickerWidth)
    }

  private func browser(selection: Bool) -> some View {
    VStack(spacing: 0) {
      WorkspaceMasterHeader(prompt: "搜索思考", search: $search) {
        HStack(spacing: WorkbenchDesign.Space.small) {
          ScrollView(.horizontal) {
            WorkspaceFilters(values: tags, selection: $tag, title: { $0 })
          }.scrollIndicators(.hidden)
          Button("管理标签", systemImage: "tag") { managingTags = true }
            .labelStyle(.iconOnly).buttonStyle(.borderless).help("管理标签")
            .popover(isPresented: $managingTags) { tagManagement }
        }
      }
      WorkspaceList(selection: selection ? $selected : nil, inset: WorkbenchDesign.masterInset) {
        ForEach(thoughts) { item in
          if selection {
            ThoughtSummary(item: item).tag(item.id)
          } else {
            NavigationLink(value: ThoughtRoute(id: item.id)) { ThoughtSummary(item: item) }
          }
        }
      }
    }.background(WorkbenchDesign.canvas)
  }
}

/// The Today entry uses the same full editor. Empty dismissal leaves no record.
struct NewThoughtView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var id = UUID().uuidString.lowercased()
  @State private var closing = false
  var body: some View {
    NavigationStack {
      ThoughtEditor(id: id, initialTags: []).toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            guard !closing, let store = session.workspace else { return }
            closing = true
            Task {
              await session.thoughtEditing.flush(id: id, store: store)
              closing = false
              if session.thoughtEditing.buffers[id]?.error == nil { dismiss() }
            }
          }.disabled(closing)
        }
      }
    }
    #if os(macOS)
      .frame(
        minWidth: WorkbenchDesign.ThoughtLayout.editorWidth,
        minHeight: WorkbenchDesign.ThoughtLayout.editorHeight)
    #endif
  }
}

struct ThoughtEditor: View {
  let id: String
  var initialTags: [String]? = nil
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var deletion = false
  @State private var deleting = false
  @State private var focused = false
  @State private var reviewing = false
  private var item: WorkspaceItem? { session.workspace?.snapshot.item(.reflections, id) }
  private var buffer: ThoughtEditing.Buffer? { session.thoughtEditing.buffers[id] }
  var body: some View {
    Group {
      if let store = session.workspace, item != nil || buffer != nil || initialTags != nil {
        VStack(spacing: 0) {
          ThoughtTagPicker(
            tags: buffer?.tags ?? item.map(thoughtTags) ?? initialTags ?? [],
            suggestions: allTags
          ) { tags in
            try session.thoughtEditing.stageTags(id: id, tags: tags, store: store)
          }.padding(.horizontal, WorkbenchDesign.pageInset)
            .padding(.top, WorkbenchDesign.Space.medium)
            .padding(.bottom, WorkbenchDesign.Space.small)
          if let error = buffer?.error {
            HStack(alignment: .top, spacing: WorkbenchDesign.Space.small) {
              Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
              Text(error).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
              if buffer?.conflict != nil {
                Button("核对版本") { reviewing = true }.buttonStyle(.borderless)
              } else {
                Button("重试") {
                  Task { await session.thoughtEditing.flush(id: id, store: store) }
                }.buttonStyle(.borderless)
              }
            }.padding(.horizontal, WorkbenchDesign.pageInset)
              .padding(.vertical, WorkbenchDesign.Space.small)
              .accessibilityIdentifier("thought.save.error")
          }
          ZStack(alignment: .topLeading) {
            ThoughtTextEditor(
              text: Binding(
                get: { buffer?.text ?? item?[.content].string ?? "" },
                set: { session.thoughtEditing.stage(id: id, text: $0, store: store) }),
              focused: $focused
            )
            .accessibilityIdentifier("thought.content")
            if (buffer?.text ?? item?[.content].string ?? "").isEmpty {
              Text("标题").font(.title2.bold()).foregroundStyle(.tertiary)
                .padding(WorkbenchDesign.Space.small).allowsHitTesting(false)
            }
          }.padding(.horizontal, WorkbenchDesign.pageInset)
            .padding(.bottom, WorkbenchDesign.pageInset)
        }.readablePage().background(WorkbenchDesign.canvas).disabled(deleting)

      } else {
        ContentUnavailableView("思考已删除", systemImage: "text.bubble")
      }
    }.navigationTitle("").phoneDetailNavigation()
      .onAppear {
        if let item {
          session.thoughtEditing.begin(item)
        } else if let initialTags {
          session.thoughtEditing.beginNew(id: id, tags: initialTags)
        }
        if initialTags != nil { focused = true }
      }
      .onChange(of: item) { _, value in
        if let value { session.thoughtEditing.begin(value) }
      }
      .onChange(of: buffer?.conflict) { _, version in
        if version == nil { reviewing = false }
      }
      .sheet(isPresented: $reviewing) {
        if let store = session.workspace, let buffer, let saved = buffer.conflict {
          ThoughtConflictReview(
            saved: saved, draft: .init(text: buffer.text, tags: buffer.tags),
            error: buffer.error
          ) { version, keepDraft in
            await session.thoughtEditing.resolve(
              id: id, reviewed: version, keepDraft: keepDraft, store: store)
          }
        }
      }
      .onDisappear {
        guard let store = session.workspace else { return }
        Task {
          await session.thoughtEditing.flush(id: id, store: store)
          if let buffer = session.thoughtEditing.buffers[id], !buffer.persisted,
            buffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            session.thoughtEditing.remove(id)
          }
        }
      }
      .toolbar {
        #if os(iOS)
          if focused {
            ToolbarItem(placement: .confirmationAction) {
              Button("完成") { focused = false }.accessibilityIdentifier("keyboard.done")
            }
          }
        #endif
        ToolbarItem(placement: .secondaryAction) {
          if item != nil || !(buffer?.text ?? "").isEmpty {
            Button("删除", systemImage: "trash", role: .destructive) { deletion = true }
          }
        }
      }
      .confirmationDialog("删除这篇思考？", isPresented: $deletion) {
        Button("删除", role: .destructive) {
          guard let store = session.workspace else { return }
          deleting = true
          session.run {
            defer { deleting = false }
            await session.thoughtEditing.flush(id: id, store: store)
            if store.snapshot.item(.reflections, id) != nil {
              _ = try await store.perform(.delete(.reflections, id: id))
            }
            session.thoughtEditing.remove(id)
            dismiss()
          }
        }
      }
  }
  private var allTags: [String] {
    Array(
      Set(
        (session.workspace?.snapshot[.reflections] ?? []).flatMap { item in
          session.thoughtEditing.buffers[item.id]?.tags ?? thoughtTags(item)
        } + session.thoughtEditing.pendingItems.flatMap(thoughtTags))
    ).sorted()
  }
}

private struct ThoughtConflictReview: View {
  let saved: ThoughtContentVersion
  let draft: ThoughtContentVersion
  let error: String?
  let resolve: (ThoughtContentVersion, Bool) async -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var resolving = false

  var body: some View {
    WorkspaceEntrySheet(
      title: "核对思考版本", confirmTitle: "保存我的版本", saving: resolving, canSave: true,
      cancel: { dismiss() }, save: { choose(keepDraft: true) }
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: WorkbenchDesign.Space.section) {
          version("我的输入", draft)
          version("已保存版本", saved)
          if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: WorkbenchDesign.ThoughtLayout.tagListHeight)
      Button("使用已保存版本") { choose(keepDraft: false) }.disabled(resolving)
    }
  }

  private func version(_ title: String, _ version: ThoughtContentVersion) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
      Text(title).font(.headline)
      Text(version.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if !version.tags.isEmpty {
        Text(version.tags.map { "#" + $0 }.joined(separator: " "))
          .font(.footnote).foregroundStyle(.secondary)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).workspaceCard()
  }

  private func choose(keepDraft: Bool) {
    guard !resolving else { return }
    resolving = true
    Task {
      await resolve(saved, keepDraft)
      resolving = false
    }
  }
}

struct ThoughtTagPicker: View {
  let tags: [String]
  let suggestions: [String]
  let change: ([String]) throws -> Void
  @State private var showing = false
  @State private var newTag = ""
  @State private var error: String?
  @FocusState private var focused: Bool
  var body: some View {
    HStack(spacing: WorkbenchDesign.Space.small) {
      Button(tags.isEmpty ? "添加标签" : "标签", systemImage: "tag") { showing.toggle() }
        .buttonStyle(.borderless).accessibilityIdentifier("thought.tags")
        .popover(isPresented: $showing) { picker.presentationCompactAdaptation(.popover) }
      ScrollView(.horizontal) {
        HStack(spacing: WorkbenchDesign.Space.small) {
          ForEach(tags, id: \.self) { tag in
            Button {
              apply(tags.filter { $0 != tag })
            } label: {
              HStack(spacing: 4) {
                Text("#" + tag)
                Image(systemName: "xmark").imageScale(.small)
              }
              .font(.subheadline).padding(.horizontal, WorkbenchDesign.Space.small)
              .padding(.vertical, 5)
              .background(WorkbenchDesign.selectionBackground, in: .capsule)
            }.buttonStyle(.plain).foregroundStyle(.tint)
              .accessibilityLabel("移除标签 " + tag)
          }
        }
      }.scrollIndicators(.hidden)
    }.frame(minHeight: WorkbenchDesign.rowMinimum, alignment: .leading)
  }
  private var picker: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      tagEntry
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(Set(suggestions + tags)).sorted(), id: \.self) { tag in
            suggestion(tag)
          }
        }
      }.frame(maxHeight: WorkbenchDesign.ThoughtLayout.tagListHeight)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }.padding(WorkbenchDesign.Space.section)
      .frame(width: WorkbenchDesign.ThoughtLayout.tagPickerWidth)
  }
  private var tagEntry: some View {
    WorkspaceComposerLayout {
      TextField("新标签", text: $newTag).textFieldStyle(.plain).focused($focused)
        .workspaceInput(focused: focused).onSubmit { add() }
        .accessibilityIdentifier("thought.tag.input")
      Button("添加标签", systemImage: "plus") { add() }.labelStyle(.iconOnly)
        .buttonStyle(WorkspaceSubmitButtonStyle())
        .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("thought.tag.add")
    }
  }
  private func suggestion(_ tag: String) -> some View {
    Button {
      _ = apply(tags.contains(tag) ? tags.filter { $0 != tag } : tags + [tag])
    } label: {
      HStack {
        Text("#" + tag).foregroundStyle(.primary)
        Spacer()
        if tags.contains(tag) { Image(systemName: "checkmark").foregroundStyle(.tint) }
      }.frame(minHeight: WorkbenchDesign.rowMinimum).frame(
        maxWidth: .infinity,
        alignment: .leading
      ).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel("标签 " + tag)
      .accessibilityAddTraits(tags.contains(tag) ? .isSelected : [])
  }
  private func add() {
    let value = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard !value.isEmpty else { return }
    if apply(tags.contains(value) ? tags : tags + [value]) {
      newTag = ""
      showing = false
    }
  }
  @discardableResult private func apply(_ next: [String]) -> Bool {
    do {
      try change(next)
      error = nil
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
}
struct CourseOccurrence: Identifiable {
  let course: WorkspaceItem
  let meeting: WorkspaceItem
  let day: Date
  let start: String
  let end: String
  let inactiveLabel: String?
  var id: String { meeting.id + Clock.day(day) }
}
func courseOccurrences(
  snapshot: WorkspaceSnapshot, day: Date, allWeek: Bool = false, includeInactive: Bool = false
)
  -> [CourseOccurrence]
{
  let calendar = Clock.calendar
  let days =
    allWeek
    ? (0..<7).compactMap {
      calendar.date(
        byAdding: .day, value: $0, to: calendar.dateInterval(of: .weekOfYear, for: day)!.start)
    } : [day]
  return days.flatMap { date in
    snapshot[.courseMeetings].compactMap { meeting -> CourseOccurrence? in
      guard let course = snapshot.item(.courses, meeting[.courseID].string),
        let term = snapshot.item(.semesters, course[.semesterID].string),
        let first = try? Clock.parse(term[.firstMonday].string + "T00:00:00+08:00"),
        date >= first
      else { return nil }
      let week =
        (calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day ?? -7)
        / 7 + 1
      let weekday = (calendar.component(.weekday, from: date) + 5) % 7 + 1
      let weeks = (try? JSONValue(json: meeting[.weeks].string).array.map(\.int)) ?? []
      guard
        week > 0 && week <= term[.weeks].int && weeks.contains(Int64(week))
          && meeting[.weekday].int == weekday
      else { return nil }
      let periods = (try? JSONValue(json: term[.periods].string).array) ?? []
      let start = periods.first { $0["number"] == meeting[.periodStart] }?["start"].string ?? ""
      let end = periods.first { $0["number"] == meeting[.periodEnd] }?["end"].string ?? ""
      var inactiveLabel: String?
      if course.status == "paused" { inactiveLabel = "已暂停" }
      if course.status == "done" {
        let completed = try? Clock.parse(course.fields.text("completed_at"))
        let begins = try? Clock.parse(Clock.day(date) + "T" + start + ":00+08:00")
        if let completed, let begins {
          if begins >= completed { inactiveLabel = "已完结" }
        } else {
          inactiveLabel = "已完结"
        }
      }
      guard includeInactive || inactiveLabel == nil else { return nil }
      return CourseOccurrence(
        course: course, meeting: meeting, day: date, start: start, end: end, inactiveLabel: inactiveLabel)
    }
  }.sorted { (Clock.day($0.day), $0.start) < (Clock.day($1.day), $1.start) }
}
struct CoursesView: View {
  @Environment(AppSession.self) private var session
  @State private var reminders = false
  @State private var addCourse = false
  @State private var editSemester = false
  @State private var addSemester = false
  @State private var week = Date()
  @State private var semesterID = ""
  private var semesters: [WorkspaceItem] {
    (session.workspace?.snapshot[.semesters] ?? []).sorted { $0[.firstMonday].string > $1[.firstMonday].string }
  }
  @State private var showTable = true
  @State private var selectedCourse: WorkspaceItem?
  @State private var addedCourseID: String?
  private var selectedSemester: WorkspaceItem? { semesters.first { $0.id == semesterID } }
  private var courses: [WorkspaceItem] {
    let rows = (session.workspace?.snapshot[.courses] ?? []).filter {
      $0[.semesterID].string == semesterID
    }
    guard let addedCourseID, let row = rows.first(where: { $0.id == addedCourseID }) else { return rows }
    return [row] + rows.filter { $0.id != addedCourseID }
  }
  var body: some View {
    VStack(spacing: WorkbenchDesign.Space.medium) {
      if semesters.isEmpty {
        ContentUnavailableView {
          Label("暂无学期", systemImage: "graduationcap")
        } description: {
          Text("先新建一个学期，再添加你的课程。")
        } actions: {
          Button("新建学期") { addSemester = true }
            .buttonStyle(.borderedProminent)
        }
      } else if courses.isEmpty {
        ContentUnavailableView {
          Label("本学期暂无课程", systemImage: "graduationcap")
        } actions: {
          Button("添加课程") { addCourse = true }
            .buttonStyle(.borderedProminent)
        }
      } else if showTable {
        courseHeader
        CourseSchedule(week: week, semesterID: semesterID) { selectedCourse = $0 }
      } else {
        courseHeader
        ScrollView {
          CollectionBoardLayout {
            ForEach(courses) { item in
              CourseCard(item: item) { selectedCourse = item }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .workspacePage()
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            if semesters.isEmpty {
              Button("新建学期", systemImage: "calendar.badge.plus") { addSemester = true }
            } else {
              Button("添加课程", systemImage: "plus") { addCourse = true }
              Picker("学期", selection: $semesterID) {
                ForEach(semesters) { Text($0.title).tag($0.id) }
              }
            }
            Button("学期管理", systemImage: "calendar.badge.clock") { editSemester = true }
            Button("课程提醒", systemImage: "bell") { reminders = true }
          } label: {
            Label("课程管理", systemImage: "ellipsis").labelStyle(.iconOnly)
          }
          .menuIndicator(.hidden)
        }
      }
      .sheet(isPresented: $addSemester) { SemesterEditor() }
      .sheet(isPresented: $reminders) { CourseRemindersView() }
      .sheet(isPresented: $addCourse) {
        CourseEditor(defaultSemesterID: semesterID) { item in
          semesterID = item[.semesterID].string
          addedCourseID = item.id
          showTable = false
        }
      }
      .sheet(isPresented: $editSemester) {
        SemesterManagementView()
      }
      .onChange(of: semesters.map(\.id), initial: true) { old, ids in
        if let added = ids.first(where: { !old.contains($0) }), !old.isEmpty { semesterID = added }
        else if !ids.contains(semesterID) {
          semesterID = semesters.first(where: { $0[.firstMonday].string <= Clock.day() })?.id ?? ids.first ?? ""
        }
      }
      .onChange(of: semesterID) { _, id in
        if let term = semesters.first(where: { $0.id == id }),
          let date = try? Clock.parse(term[.firstMonday].string + "T00:00:00+08:00") {
          let end = date.addingTimeInterval(Double(term[.weeks].int) * 7 * 86400)
          week = Date.now >= date && Date.now < end ? .now : date
        }
      }
      #if os(macOS)
        .sheet(item: $selectedCourse) { item in
          NavigationStack {
            CollectionDetail(route: .init(entity: .courses, id: item.id)).toolbar {
              ToolbarItem(placement: .cancellationAction) { Button("关闭") { selectedCourse = nil } }
            }
          }.frame(minWidth: 520, idealWidth: 680, minHeight: 460, idealHeight: 680)
        }
      #else
        .navigationDestination(
          isPresented: Binding(
            get: { selectedCourse != nil }, set: { if !$0 { selectedCourse = nil } })
        ) {
          if let selectedCourse {
            CollectionDetail(route: .init(entity: .courses, id: selectedCourse.id))
          }
        }
      #endif

  }
  private func shiftWeek(_ offset: Int) {
    week = Clock.calendar.date(byAdding: .day, value: offset * 7, to: week)!
  }
  private var courseHeader: some View {
    HStack(spacing: WorkbenchDesign.Space.small) {
      WorkspaceFilters(values: [true, false], selection: $showTable, title: { $0 ? "课表" : "课程" })
      Spacer(minLength: 0)
      if showTable {
        Button("上一周", systemImage: "chevron.left") { shiftWeek(-1) }.labelStyle(.iconOnly)
        Text(weekLabel).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        Button("下一周", systemImage: "chevron.right") { shiftWeek(1) }.labelStyle(.iconOnly)
      }
    }
  }

  private var weekLabel: String {
    let monday = Clock.calendar.dateInterval(of: .weekOfYear, for: week)!.start
    let sunday = Clock.calendar.date(byAdding: .day, value: 6, to: monday)!
    var format = Date.FormatStyle().month(.twoDigits).day(.twoDigits)
    format.timeZone = Clock.calendar.timeZone
    let range = monday.formatted(format) + "–" + sunday.formatted(format)
    guard let term = selectedSemester,
      let first = try? Clock.parse(term[.firstMonday].string + "T00:00:00+08:00"),
      let days = Clock.calendar.dateComponents([.day], from: first, to: monday).day,
      days >= 0, days / 7 < term[.weeks].int
    else { return range }
    return "第\(days / 7 + 1)周 · " + range
  }

}
