import SwiftUI
import WorkBenchActivity

enum TaskFilter: String, CaseIterable, Identifiable {
  case today = "今日"
  case later = "以后"
  case done = "已完成"
  case abandoned = "放弃"
  var id: String { rawValue }
}
struct TodayView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.openCollection) private var openCollection
  @State private var records = false
  @State private var filter: TaskFilter = .today
  @State private var adding = false
  @State private var addingThought = false
  @State private var createEntity: WorkspaceEntity = .tasks
  @State private var recordSection = "随手记"
  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var notes: [WorkspaceItem] {
    snapshot[.notes].filter { $0.status != "archived" }.sorted { $0.createdAt > $1.createdAt }
  }
  private var tasks: [WorkspaceItem] { taskItems(filter) }
  private var completedToday: [WorkspaceItem] {
    tasksCompleted(on: .now, in: snapshot[.tasks])
  }
  private func taskItems(_ value: TaskFilter) -> [WorkspaceItem] {
    let today = Clock.day()
    return snapshot[.tasks].filter { item in
      switch value {
      case .today:
        isTaskDueForToday(item, day: today)
      case .later:
        item.status == "todo"
          && (item[.plannedDate].isNull || item[.plannedDate].string > today)
      case .done: item.status == "done"
      case .abandoned: item.status == "abandoned"
      }
    }.sorted(by: taskImportanceOrder)
  }
  var body: some View {
    Group {
      #if os(macOS)
        GeometryReader { geometry in
          if geometry.size.width >= 840 {
            VStack(alignment: .leading, spacing: 20) {
              focusBar
              classes
              HStack(alignment: .top, spacing: WorkbenchDesign.gap) {
                WorkspacePanel(title: "任务", symbol: "checklist", add: { create(.tasks) }) {
                  taskPanel
                }
                .frame(
                  width: (geometry.size.width - 2 * WorkbenchDesign.pageInset - 2
                    * WorkbenchDesign.gap - 1)
                    * 0.61)
                Rectangle().fill(WorkbenchDesign.line).frame(width: 1)
                WorkspacePanel(title: "记录", symbol: "square.and.pencil", add: addRecord) {
                  recordPanel
                }
              }.frame(maxHeight: .infinity)
            }.workspacePage()
          } else {
            compactPage
          }
        }
      #else
        compactPage
      #endif
    }
    .phoneCreateAction(records ? "添加" + recordSection : "添加任务") {
      records ? addRecord() : create(.tasks)
    }
    .sheet(isPresented: $adding) { NewItemForm(entity: createEntity) }
    .sheet(isPresented: $addingThought) { NewThoughtView() }
    .navigationDestination(for: ThoughtRoute.self) {
      ThoughtEditor(id: $0.id)
        #if os(iOS)
          .toolbarVisibility(.visible, for: .navigationBar)
        #endif
    }
  }
  private var focusBar: some View {
    HStack(spacing: 16) {
      Image(systemName: "timer").font(.title3).foregroundStyle(.tint)
      FocusControls().frame(maxWidth: 440, alignment: .leading)
      Spacer(minLength: 0)
      #if os(macOS)
        Text(Date(), format: .dateTime.month().day().weekday(.wide)).font(.subheadline)
          .foregroundStyle(.secondary)
      #endif
    }.padding(.horizontal, 14).padding(.vertical, 8)
      .background(
        LinearGradient(
          colors: [Color.accentColor.opacity(0.055), Color.accentColor.opacity(0.015)],
          startPoint: .leading, endPoint: .trailing), in: .rect(cornerRadius: 12))
  }
  @ViewBuilder private var classes: some View {
    let rows = courseOccurrences(snapshot: snapshot, day: .now)
    if !rows.isEmpty {
      ScrollView(.horizontal) {
        HStack(spacing: 18) {
          ForEach(rows) { row in
            NavigationLink(value: CollectionRoute(entity: .courses, id: row.course.id)) {
              HStack(spacing: 10) {
                Image(systemName: "graduationcap").foregroundStyle(.secondary)
                Text(row.start + "–" + row.end).monospacedDigit().foregroundStyle(.secondary)
                Text(row.course.title).lineLimit(1)
                Text(row.meeting[.room].string).foregroundStyle(.secondary)
              }.font(.subheadline).padding(.vertical, 5)
            }.buttonStyle(.plain)
          }
        }
      }.scrollIndicators(.hidden)
    }
  }
  private var taskFilters: some View {
    ScrollView(.horizontal) {
      WorkspaceFilters(
        values: TaskFilter.allCases, selection: $filter, title: { $0.rawValue },
        count: { taskItems($0).count })
    }.scrollIndicators(.hidden)
  }
  private var taskPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      taskFilters
      ScrollView {
        LazyVStack(spacing: 0) {
          taskRows(dividers: true)
        }.padding(.vertical, 2)
      }.accessibilityIdentifier("today.tasks")
    }
  }
  @ViewBuilder private func taskRows(dividers: Bool = false) -> some View {
    ForEach(tasks) { taskRow($0, divider: dividers) }
    if filter == .today, !completedToday.isEmpty {
      Section {
        ForEach(completedToday) { taskRow($0, divider: dividers) }
      } header: {
        HStack(spacing: WorkbenchDesign.Space.small) {
          Text("今日已完成")
          Text(completedToday.count.formatted()).monospacedDigit()
        }
        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, WorkbenchDesign.Space.section)
        .padding(.bottom, WorkbenchDesign.Space.small)
        .textCase(nil)
        .accessibilityIdentifier("today.completed")
      }
    }
  }
  @ViewBuilder private func taskRow(_ item: WorkspaceItem, divider: Bool) -> some View {
    if divider {
      VStack(spacing: 0) {
        ItemRow(item: item).padding(.horizontal, 2)
        Rectangle().fill(WorkbenchDesign.line).frame(height: 0.5)
      }
    } else {
      ItemRow(item: item)
    }
  }
  private var recordFilters: some View {
    ScrollView(.horizontal) {
      WorkspaceFilters(values: ["随手记", "思考", "学习", "项目"], selection: $recordSection, title: { $0 })
    }.scrollIndicators(.hidden)
  }
  private var recordPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      recordFilters
      ScrollView { LazyVStack(spacing: 0) { recordRows } }.accessibilityIdentifier("today.records")
    }
  }
  @ViewBuilder private var recordRows: some View {
    if recordSection == "随手记" {
      ForEach(notes) { note in
        ItemRow(item: note)
        Divider().opacity(0.4)
      }
    } else if recordSection == "思考" {
      ForEach(snapshot[.reflections].sorted { $0[.day].string > $1[.day].string }) { thought in
        NavigationLink(value: ThoughtRoute(id: thought.id)) { ThoughtSummary(item: thought) }
          .buttonStyle(.plain)
        Divider().opacity(0.4)
      }
    } else {
      let entity: WorkspaceEntity = recordSection == "学习" ? .learning : .projects
      ForEach(snapshot[entity].filter { $0.status != "done" }) { item in
        CollectionCard(item: item) {
          openCollection?(CollectionRoute(entity: entity, id: item.id))
        }.padding(.vertical, WorkbenchDesign.Space.small)
      }
    }
  }
  private var compactPage: some View {
    VStack(spacing: 12) {
      focusBar.padding(.horizontal, WorkbenchDesign.pageInset)
      classes.padding(.horizontal, WorkbenchDesign.pageInset)
      WorkspaceFilters(values: [false, true], selection: $records, title: { $0 ? "记录" : "任务" })
        .frame(maxWidth: .infinity)
      if records {
        recordFilters.padding(.horizontal, WorkbenchDesign.pageInset)
        ScrollView {
          LazyVStack(spacing: 0) { recordRows }.padding(.horizontal, WorkbenchDesign.pageInset)
        }
      } else {
        taskFilters.padding(.horizontal, WorkbenchDesign.pageInset)
        WorkspaceList { taskRows() }
      }
    }.padding(.top, 10).background(WorkbenchDesign.canvas)
  }
  private func create(_ entity: WorkspaceEntity) {
    createEntity = entity
    adding = true
  }
  private func addRecord() {
    if recordSection == "思考" {
      addingThought = true
    } else {
      create(recordSection == "学习" ? .learning : recordSection == "项目" ? .projects : .notes)
    }
  }
}
struct FocusControls: View {
  @Environment(AppSession.self) private var session
  @State private var selected = ""
  var current: WorkspaceItem? {
    guard let focus = session.focusStatus else { return nil }
    return session.workspace?.snapshot.item(.focusSessions, focus.id)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let current {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              session.workspace?.snapshot.item(.tasks, current.fields.text("task_id"))?.title
                ?? "自由专注"
            ).font(.headline).lineLimit(2)
            if let focus = session.focusStatus {
              FocusTimerText(state: focus.timer).font(.title2.monospacedDigit())
                .accessibilityIdentifier("focus.elapsed")
            }
          }
          Spacer()
          Button(
            current.status == "running" ? "暂停" : "继续",
            systemImage: current.status == "running" ? "pause" : "play"
          ) {
            session.run {
              _ = try await session.workspace?.perform(
                current.status == "running"
                  ? .pauseFocus
                  : .startFocus(
                    taskID: current.fields[value: "task_id"].isNull
                      ? nil : current.fields.text("task_id")))
            }
          }.labelStyle(.iconOnly).buttonStyle(.bordered).accessibilityIdentifier("focus.toggle")
          Button("结束", systemImage: "stop.fill") {
            session.run {
              _ = try await session.workspace?.perform(.endFocus(id: current.id, resumeHint: nil))
            }
          }.labelStyle(.iconOnly).buttonStyle(.bordered).accessibilityIdentifier("focus.end")
        }
      } else {
        HStack(spacing: 12) {
          Picker("专注内容", selection: $selected) {
            Text("自由专注").tag("")
            ForEach((session.workspace?.snapshot[.tasks] ?? []).filter { $0.status == "todo" }) {
              Text($0.title).tag($0.id)
            }
          }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 300, alignment: .leading)
          Button("开始", systemImage: "play.fill") {
            session.run {
              _ = try await session.workspace?.perform(
                .startFocus(taskID: selected.isEmpty ? nil : selected))
            }
          }.buttonStyle(.borderedProminent).accessibilityIdentifier("focus.start")
        }
      }
      if let notice = session.focusSurfaceNotice {
        HStack {
          Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
          Button("重试") { Task { await session.refreshFocusSurfaces() } }.font(.caption)
        }
      }
    }.padding(.vertical, 6)
  }
}
struct CollectionRoute: Hashable {
  let entity: WorkspaceEntity
  let id: String
}
struct CollectionsView: View {
  let entity: WorkspaceEntity
  @Environment(AppSession.self) private var session
  @State private var completed = false
  @State private var adding = false
  @State private var search = ""
  @State private var detail: WorkspaceItem?
  private var items: [WorkspaceItem] {
    let rows = (session.workspace?.snapshot[entity] ?? []).filter {
      ($0.status == "done") == completed
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
    }.sorted {
      ($0.fields.integer("position"), $0.createdAt) < ($1.fields.integer("position"), $1.createdAt)
    }
    return entity == .learning ? treeOrder(rows) : rows
  }
  var body: some View {
    VStack(spacing: 16) {
      HStack(spacing: 16) {
        WorkspaceFilters(
          values: [false, true], selection: $completed, title: { $0 ? "已完结" : "进行中" })
        Spacer(minLength: 0)
        WorkspaceSearch(prompt: "搜索", text: $search).frame(maxWidth: 230)
      }
      ScrollView {
        CollectionBoardLayout {
          ForEach(items) { item in CollectionCard(item: item) { detail = item } }
        }.padding(.bottom, WorkbenchDesign.Space.group)
      }.scrollDismissesKeyboard(.interactively)
    }.workspacePage()
      .phoneCreateAction("新建") { adding = true }
      #if os(macOS)
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button("新建", systemImage: "plus") { adding = true }
          }
        }
      #endif
      .sheet(isPresented: $adding) { NewItemForm(entity: entity) }
      #if os(macOS)
        .sheet(item: $detail) { item in
          NavigationStack {
            CollectionDetail(route: .init(entity: entity, id: item.id)).toolbar {
              ToolbarItem(placement: .cancellationAction) { Button("关闭") { detail = nil } }
            }
          }
          .frame(minWidth: 520, idealWidth: 680, minHeight: 420, idealHeight: 680)
        }
      #else
        .navigationDestination(
          isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })
        ) {
          if let detail { CollectionDetail(route: .init(entity: entity, id: detail.id)) }
        }
      #endif

  }
}
struct CollectionDetail: View {
  let route: CollectionRoute
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @FocusState private var addingFocused: Bool
  @State private var deleting = false
  @State private var addNote = false
  @State private var editCourse = false
  @State private var addMeeting = false
  @State private var editMeeting: WorkspaceItem?
  var item: WorkspaceItem? { session.workspace?.snapshot.item(route.entity, route.id) }
  var body: some View {
    Group {
      if let item {
        Group {
          if route.entity == .courses {
            coursePage(item)
          } else {
            collectionPage(item)
          }
        }
        .background(WorkbenchDesign.canvas)
        .navigationTitle("").phoneDetailNavigation()
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            WorkspaceMoreMenu {
              if route.entity == .courses {
                Button("编辑课程信息", systemImage: "pencil") { editCourse = true }
                Button("添加上课安排", systemImage: "calendar.badge.plus") { addMeeting = true }
              } else {
              Button("添加随手记", systemImage: "square.and.pencil") { addNote = true }
              Button(item.status == "done" ? "恢复进行中" : "标记完结", systemImage: "checkmark") {
                session.run {
                  _ = try await session.workspace?.perform(
                    .update(
                      route.entity, id: route.id,
                      fields: [.status: .string(item.status == "done" ? "active" : "done")]))
                }
              }
              Button("删除", systemImage: "trash", role: .destructive) { deleting = true }
              }
            }
              .accessibilityIdentifier("collection.actions")
          }
        }
        .sheet(isPresented: $addNote) { NewItemForm(entity: .notes, association: item) }
        .sheet(isPresented: $editCourse) { CourseEditor(course: item) }
        .sheet(isPresented: $addMeeting) { MeetingEditor(course: item) }
        .sheet(item: $editMeeting) { MeetingEditor(course: item, meeting: $0) }
        .confirmationDialog("删除这个集合？", isPresented: $deleting, titleVisibility: .visible) {
          Button("删除", role: .destructive) {
            session.run {
              _ = try await session.workspace?.perform(.delete(route.entity, id: route.id))
              dismiss()
            }
          }
        }
      } else {
        EmptyState(title: "内容不存在", symbol: "folder", detail: "返回列表继续查看。")
      }
    }
  }
  private func collectionPage(_ item: WorkspaceItem) -> some View {
    let tasks = linkedTasks(item)
    let active = tasks.filter { $0.status == "todo" }.sorted(by: taskImportanceOrder)
    let finished = tasks.filter { $0.status != "todo" }.sorted(by: taskImportanceOrder)
    let notes = (session.workspace?.snapshot[.notes] ?? []).filter {
      $0[associationField] == .string(item.id) && $0.status != "archived"
    }
    return WorkspaceDetailPage(width: WorkbenchDesign.CollectionLayout.readingWidth) {
      HStack(alignment: .firstTextBaseline, spacing: WorkbenchDesign.Space.medium) {
        Image(systemName: route.entity == .learning ? "book" : "folder")
          .font(.title2).foregroundStyle(.secondary)
        InlineItemText(item.title) {
          _ = try await session.workspace?.perform(
            .update(route.entity, id: route.id, fields: [.title: .string($0)]))
        }.font(WorkbenchDesign.Typography.detailTitle)
        if item.status == "done" {
          Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            .accessibilityLabel("已完结")
        }
      }.padding(.vertical, WorkbenchDesign.Space.small)
      WorkspaceDetailSection(title: "待办", count: active.count) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(active) { task in
            ItemRow(item: task, showsAssociation: false)
            if task.id != active.last?.id { Divider().opacity(0.35) }
          }
        }
        CollectionTaskEntry(collection: item, focused: $addingFocused)
        if !finished.isEmpty {
          DisclosureGroup("已结束 · \(finished.count)") {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(finished) { ItemRow(item: $0, showsAssociation: false) }
            }
          }.font(.subheadline).foregroundStyle(.secondary)
            .padding(.top, WorkbenchDesign.Space.small)
        }
      }
      if !notes.isEmpty {
        WorkspaceDetailSection(title: "随手记", count: notes.count) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(notes) { note in
              ItemRow(item: note, showsAssociation: false)
              if note.id != notes.last?.id { Divider() }
            }
          }
        }
      }
      if route.entity == .learning {
        WorkspaceDetailSection(title: "学习步骤") {
          ForEach(
            (session.workspace?.snapshot[.lessons] ?? []).filter {
              $0[.learningID] == .string(item.id)
            }.sorted { $0[.position].int < $1[.position].int }
          ) { lesson in
            HStack {
              Button {
                session.run {
                  _ = try await session.workspace?.perform(
                    .update(
                      .lessons, id: lesson.id,
                      fields: [.done: .integer(lesson[.done].bool ? 0 : 1)]))
                }
              } label: {
                Image(systemName: lesson[.done].bool ? "checkmark.circle.fill" : "circle")
              }.buttonStyle(.plain)
              InlineItemText(lesson.title) {
                _ = try await session.workspace?.perform(
                  .update(.lessons, id: lesson.id, fields: [.title: .string($0)]))
              }
              Button("安排今日", systemImage: "sun.max") {
                session.run {
                  _ = try await session.workspace?.perform(
                    .scheduleLesson(id: lesson.id, plannedDate: Clock.day()))
                }
              }.labelStyle(.iconOnly)
              WorkspaceMoreMenu {
                TreeMoveMenu(item: lesson)
                Button("删除步骤", systemImage: "trash", role: .destructive) {
                  session.run {
                    _ = try await session.workspace?.perform(
                      .delete(.lessons, id: lesson.id))
                  }
                }
              }
            }.padding(
              .leading,
              CGFloat(treeDepth(lesson, rows: session.workspace?.snapshot[.lessons] ?? []))
                * 12
            )
          }
          NewLessonRow(learningID: item.id)
        }
      }
      WorkspaceDetailSection(title: "备注") { ItemRemarks(item: item) }
    }.accessibilityIdentifier("collection.detail.content")
  }
  private func coursePage(_ course: WorkspaceItem) -> some View {
    WorkspaceDetailPage {
      VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchDesign.Space.medium) {
          InlineItemText(course.title) {
            _ = try await session.workspace?.perform(
              .update(.courses, id: course.id, fields: [.title: .string($0)]))
          }.font(WorkbenchDesign.Typography.detailTitle)

        }
        if !course[.teacher].string.isEmpty {
          Label(course[.teacher].string, systemImage: "person").font(.subheadline).foregroundStyle(
            .secondary)
        }
        if let term = session.workspace?.snapshot.item(.semesters, course[.semesterID].string) {
          Text(term.title).font(.caption).foregroundStyle(.secondary)
        }
        CourseScheduleStatus(course: course)
      }
      VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
        HStack {
          Text("上课安排").font(.headline)
          Spacer()

        }
        ForEach(courseMeetings(course)) { meeting in
          HStack(alignment: .top, spacing: WorkbenchDesign.Space.medium) {
            Button {
              editMeeting = meeting
            } label: {
              CourseMeetingSummary(
                meeting: meeting,
                semester: session.workspace?.snapshot.item(.semesters, course[.semesterID].string)
              )
              .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            WorkspaceMoreMenu(title: "上课安排操作") {
              Button("修改安排", systemImage: "pencil") { editMeeting = meeting }
              Button("删除安排", systemImage: "trash", role: .destructive) {
                session.run {
                  _ = try await session.workspace?.perform(.delete(.courseMeetings, id: meeting.id))
                }
              }
            }
          }
          if meeting.id != courseMeetings(course).last?.id { Divider() }
        }
        if courseMeetings(course).isEmpty {
          Text("暂无上课安排").font(.subheadline).foregroundStyle(.secondary)
        }
      }.workspaceCard()
      VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
        Text("待办事项").font(.headline)
        ForEach(linkedTasks(course).filter { $0.status == "todo" }.sorted(by: taskImportanceOrder))
        { task in
          ItemRow(item: task, showsAssociation: false)
          Divider()
        }
        CollectionTaskEntry(collection: course, focused: $addingFocused)
        let finished = linkedTasks(course).filter { $0.status != "todo" }
        if !finished.isEmpty {
          DisclosureGroup("已结束 · \(finished.count)") {
            ForEach(finished) { ItemRow(item: $0, showsAssociation: false) }
          }
          .font(.subheadline).foregroundStyle(.secondary)
        }
      }.workspaceCard()
      WorkspaceDetailSection(title: "课程备注") {
        ItemRemarks(item: course)
      }
      let notes = (session.workspace?.snapshot[.notes] ?? []).filter {
        $0[.courseID] == .string(course.id) && $0.status != "archived"
      }
      if !notes.isEmpty {
        VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
          Text("随手记").font(.headline)
          ForEach(notes) { ItemRow(item: $0, showsAssociation: false) }
        }.workspaceCard()
      }
    }.accessibilityIdentifier("course.detail")
  }
  private func courseMeetings(_ course: WorkspaceItem) -> [WorkspaceItem] {
    (session.workspace?.snapshot[.courseMeetings] ?? []).filter {
      $0[.courseID] == .string(course.id)
    }
    .sorted { ($0[.weekday].int, $0[.periodStart].int) < ($1[.weekday].int, $1[.periodStart].int) }
  }
  var associationField: ItemField {
    route.entity == .projects ? .projectID : route.entity == .courses ? .courseID : .learningID
  }
  func linkedTasks(_ item: WorkspaceItem) -> [WorkspaceItem] {
    session.workspace?.snapshot[.tasks].filter { $0[associationField] == .string(item.id) } ?? []
  }
}
struct NewLessonRow: View {
  let learningID: String
  @Environment(AppSession.self) private var session
  @State private var title = ""
  @FocusState private var focused: Bool
  var body: some View {
    WorkspaceComposerLayout {
      TextField("添加学习步骤", text: $title, axis: .vertical).lineLimit(1...5)
        .focused($focused).workspaceInput(focused: focused)
        .workspaceKeyboardDone(when: focused) { focused = false }
      Button("添加", systemImage: "plus") {
        session.run {
          _ = try await session.workspace?.perform(
            .create(.lessons, fields: [.title: .string(title), .learningID: .string(learningID)]))
          title = ""
        }
      }.labelStyle(.iconOnly).buttonStyle(WorkspaceSubmitButtonStyle()).disabled(
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }
}
