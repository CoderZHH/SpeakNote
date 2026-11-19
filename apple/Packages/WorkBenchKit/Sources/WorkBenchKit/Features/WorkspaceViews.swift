import SwiftUI
import WorkBenchActivity

enum TaskFilter: String, CaseIterable, Identifiable {
  case today = "今日"
  case later = "以后"
  case done = "已完成"
  case abandoned = "放弃"
  var id: String { rawValue }
}
#if os(macOS)
extension EnvironmentValues {
  @Entry var revealedWeChatTask: String? = nil
}
#endif

struct TodayView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.openCollection) private var openCollection
  #if os(macOS)
    @Environment(\.revealedWeChatTask) private var revealedTask
  #endif
  @State private var records = false
  @State private var filter: TaskFilter = .today
  @State private var adding = false
  @State private var addingThought = false
  @State private var createEntity: WorkspaceEntity = .tasks
  @State private var initialDraft = ""
  @State private var initialPlannedToday = true
  @State private var recordSection = "随手记"
  @State private var showArchivedNotes = false
  @State private var quickTaskDraft = ""
  @State private var savingQuickTask = false
  @State private var quickNoteDraft = ""
  @State private var savingQuickNote = false
  @FocusState private var quickTaskFocused: Bool
  @FocusState private var quickNoteFocused: Bool
  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var notes: [WorkspaceItem] {
    snapshot[.notes].filter {
      showArchivedNotes ? $0.status == "archived" : $0.status != "archived"
    }.sorted { $0.createdAt > $1.createdAt }
  }
  private var archivedNoteCount: Int {
    snapshot[.notes].filter { $0.status == "archived" }.count
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
            VStack(alignment: .leading, spacing: 18) {
              todayTopHeader
              FocusControls()
              classes
              HStack(alignment: .top, spacing: WorkbenchDesign.gap) {
                WorkspacePanel(title: "任务", symbol: "checklist") {
                  taskPanel
                }
                .frame(
                  width: (geometry.size.width - 2 * WorkbenchDesign.pageInset - 2
                    * WorkbenchDesign.gap - 1)
                    * 0.60)
                Rectangle().fill(WorkbenchDesign.line).frame(width: 1)
                WorkspacePanel(
                  title: "记录",
                  symbol: "tray",
                  add: recordSection == "思考" ? { addingThought = true } : nil
                ) {
                  recordPanel
                }
              }.frame(maxHeight: .infinity)
            }.workspacePage()
          } else {
            compactPage
          }
        }
        .onChange(of: revealedTask, initial: true) { _, id in
          guard let id, let task = snapshot.item(.tasks, id) else { return }
          records = false
          filter = TaskFilter.allCases.first { taskItems($0).contains { $0.id == task.id } } ?? .today
        }
      #else
        compactPage
      #endif
    }
    .phoneCreateAction(records ? "添加" + recordSection : "添加任务") {
      records ? addRecord() : openCreateSheet(.tasks, draft: quickTaskDraft, plannedToday: filter != .later)
    }
    .sheet(isPresented: $adding) {
      NewItemForm(
        entity: createEntity,
        initialTitle: initialDraft,
        initialPlannedToday: initialPlannedToday,
        onCommitted: {
          if createEntity == .tasks { quickTaskDraft = "" }
          if createEntity == .notes { quickNoteDraft = "" }
          initialDraft = ""
        }
      )
    }
    .sheet(isPresented: $addingThought) { NewThoughtView() }
    .navigationDestination(for: ThoughtRoute.self) {
      ThoughtEditor(id: $0.id)
        #if os(iOS)
          .toolbarVisibility(.visible, for: .navigationBar)
        #endif
    }
  }

  private var todayTopHeader: some View {
    let pendingCount = taskItems(.today).count
    let doneCount = completedToday.count
    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(Date(), format: .dateTime.month().day().weekday(.wide))
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
      if pendingCount > 0 || doneCount > 0 {
        Text("已完成 \(doneCount) / \(pendingCount + doneCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(WorkbenchDesign.fieldBackground, in: .capsule)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder private var classes: some View {
    let rows = courseOccurrences(snapshot: snapshot, day: .now)
    if !rows.isEmpty {
      ScrollView(.horizontal) {
        HStack(spacing: 10) {
          ForEach(rows) { row in
            NavigationLink(value: CollectionRoute(entity: .courses, id: row.course.id)) {
              HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill")
                  .font(.caption)
                  .foregroundStyle(courseHexColor(row.course[.color].string))
                Text(row.start + "–" + row.end)
                  .monospacedDigit()
                  .foregroundStyle(.secondary)
                Text(row.course.title)
                  .fontWeight(.medium)
                  .lineLimit(1)
                if !row.meeting[.room].string.isEmpty {
                  Text(row.meeting[.room].string)
                    .foregroundStyle(.secondary)
                }
              }
              .font(.caption)
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .background(WorkbenchDesign.fieldBackground, in: .capsule)
              .overlay {
                Capsule().strokeBorder(WorkbenchDesign.line, lineWidth: 1)
              }
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
    VStack(alignment: .leading, spacing: 10) {
      taskFilters
      if filter == .today || filter == .later {
        WorkspaceQuickComposer(
          prompt: filter == .later ? "添加到以后，按回车连输…" : "添加今日待办，按回车连输…",
          text: $quickTaskDraft,
          saving: savingQuickTask,
          submitLabel: "添加任务",
          inputIdentifier: "today.task.quick.input",
          detailLabel: "设置时间、关联或附件…",
          onExpandDetail: {
            openCreateSheet(.tasks, draft: quickTaskDraft, plannedToday: filter != .later)
          },
          externalFocus: $quickTaskFocused,
          submit: { keepFocus in saveQuickTask(keepFocus: keepFocus) }
        )
      }
      revealTaskIn {
        ScrollView {
          if tasks.isEmpty && (filter != .today || completedToday.isEmpty) {
            Text(
              filter == .today
                ? "今天还没有待办，在上方直接输入即可添加"
                : "暂无\(filter.rawValue)任务"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, WorkbenchDesign.Space.section)
          } else {
            LazyVStack(spacing: 0) {
              taskRows(dividers: true)
            }.padding(.vertical, 2)
          }
        }.accessibilityIdentifier("today.tasks")
      }
    }
  }
  @ViewBuilder private func taskRows(dividers: Bool = false) -> some View {
    ForEach(tasks) { highlightedTaskRow($0, divider: dividers) }
    if filter == .today, !completedToday.isEmpty {
      Section {
        ForEach(completedToday) { highlightedTaskRow($0, divider: dividers) }
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
  private struct RevealTarget: Equatable {
    let id: String?
    let filter: TaskFilter
  }

  @ViewBuilder private func revealTaskIn<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    let view = content()
    #if os(macOS)
      ScrollViewReader { reader in
        view.task(id: RevealTarget(id: revealedTask, filter: filter)) {
          guard let revealedTask else { return }
          await Task.yield()
          guard !Task.isCancelled else { return }
          reader.scrollTo(revealedTask, anchor: .center)
        }
      }
    #else
      view
    #endif
  }

  @ViewBuilder private func highlightedTaskRow(_ item: WorkspaceItem, divider: Bool) -> some View {
    #if os(macOS)
      taskRow(item, divider: divider)
        .background(item.id == revealedTask ? WorkbenchDesign.selectionBackground : .clear)
        .id(item.id)
    #else
      taskRow(item, divider: divider)
    #endif
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
    HStack(spacing: WorkbenchDesign.Space.small) {
      WorkspaceFilters(values: ["随手记", "思考"], selection: $recordSection, title: { $0 })
      Spacer(minLength: 0)
      if recordSection == "随手记" && (archivedNoteCount > 0 || showArchivedNotes) {
        Button {
          showArchivedNotes.toggle()
        } label: {
          Label(
            showArchivedNotes ? "返回收件箱" : "已归档 \(archivedNoteCount)",
            systemImage: showArchivedNotes ? "tray" : "archivebox"
          )
          .font(.caption)
          .foregroundStyle(showArchivedNotes ? Color.accentColor : .secondary)
        }.buttonStyle(.plain)
      }
    }
  }
  private var recordPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      recordFilters
      if recordSection == "随手记" && !showArchivedNotes {
        WorkspaceQuickComposer(
          prompt: "随手记一笔，按回车即存…",
          text: $quickNoteDraft,
          saving: savingQuickNote,
          submitLabel: "快速保存随手记",
          inputIdentifier: "today.note.quick.input",
          detailLabel: "关联空间或添加附件…",
          onExpandDetail: {
            openCreateSheet(.notes, draft: quickNoteDraft, plannedToday: true)
          },
          externalFocus: $quickNoteFocused,
          submit: { keepFocus in saveQuickNote(keepFocus: keepFocus) }
        )
      }
      ScrollView { LazyVStack(spacing: 0) { recordRows } }.accessibilityIdentifier("today.records")
    }
  }
  @ViewBuilder private var recordRows: some View {
    if recordSection == "随手记" {
      if notes.isEmpty {
        Text(showArchivedNotes ? "没有已归档的随手记" : "随手记下零碎念头，稍后可一键转为今日任务")
          .font(.subheadline).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, WorkbenchDesign.Space.section)
      } else {
        ForEach(notes) { note in
          ItemRow(item: note)
          Divider().opacity(0.4)
        }
      }
    } else {
      let thoughts = snapshot[.reflections].sorted { $0[.day].string > $1[.day].string }
      if thoughts.isEmpty {
        Text("还没有思考记录，点右上角「+」写下第一篇")
          .font(.subheadline).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, WorkbenchDesign.Space.section)
      } else {
        ForEach(thoughts) { thought in
          NavigationLink(value: ThoughtRoute(id: thought.id)) { ThoughtSummary(item: thought) }
            .buttonStyle(.plain)
          Divider().opacity(0.4)
        }
      }
    }
  }
  private var compactPage: some View {
    VStack(spacing: 12) {
      FocusControls().padding(.horizontal, WorkbenchDesign.pageInset)
      classes.padding(.horizontal, WorkbenchDesign.pageInset)
      WorkspaceFilters(values: [false, true], selection: $records, title: { $0 ? "记录" : "任务" })
        .frame(maxWidth: .infinity)
      if records {
        recordFilters.padding(.horizontal, WorkbenchDesign.pageInset)
        if recordSection == "随手记" && !showArchivedNotes {
          WorkspaceQuickComposer(
            prompt: "随手记一笔…",
            text: $quickNoteDraft,
            saving: savingQuickNote,
            submitLabel: "保存随手记",
            detailLabel: "添加附件或关联…",
            onExpandDetail: { openCreateSheet(.notes, draft: quickNoteDraft, plannedToday: true) },
            externalFocus: $quickNoteFocused,
            submit: { keepFocus in saveQuickNote(keepFocus: keepFocus) }
          )
          .padding(.horizontal, WorkbenchDesign.pageInset)
        }
        ScrollView {
          LazyVStack(spacing: 0) { recordRows }.padding(.horizontal, WorkbenchDesign.pageInset)
        }
      } else {
        taskFilters.padding(.horizontal, WorkbenchDesign.pageInset)
        if filter == .today || filter == .later {
          WorkspaceQuickComposer(
            prompt: filter == .later ? "添加到以后…" : "添加今日待办…",
            text: $quickTaskDraft,
            saving: savingQuickTask,
            submitLabel: "添加任务",
            detailLabel: "更多选项…",
            onExpandDetail: {
              openCreateSheet(.tasks, draft: quickTaskDraft, plannedToday: filter != .later)
            },
            externalFocus: $quickTaskFocused,
            submit: { keepFocus in saveQuickTask(keepFocus: keepFocus) }
          )
          .padding(.horizontal, WorkbenchDesign.pageInset)
        }
        revealTaskIn { WorkspaceList { taskRows() } }
      }
    }.padding(.top, 10).background(WorkbenchDesign.canvas)
  }

  private func openCreateSheet(_ entity: WorkspaceEntity, draft: String, plannedToday: Bool) {
    createEntity = entity
    initialDraft = draft
    initialPlannedToday = plannedToday
    adding = true
  }

  private func addRecord() {
    if recordSection == "思考" {
      addingThought = true
    } else {
      openCreateSheet(.notes, draft: quickNoteDraft, plannedToday: true)
    }
  }

  private func saveQuickTask(keepFocus: Bool = false) {
    let text = quickTaskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !savingQuickTask, !text.isEmpty, let store = session.workspace else { return }
    let planToday = filter != .later
    savingQuickTask = true
    Task {
      defer { savingQuickTask = false }
      do {
        _ = try await store.perform(
          .create(
            .tasks,
            fields: [
              .title: .string(text),
              .plannedDate: planToday ? .string(Clock.day()) : .null,
            ]))
        quickTaskDraft = ""
        quickTaskFocused = keepFocus
        session.scheduleSync()
      } catch { session.error = error.localizedDescription }
    }
  }

  private func saveQuickNote(keepFocus: Bool = false) {
    let text = quickNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !savingQuickNote, !text.isEmpty, let store = session.workspace else { return }
    savingQuickNote = true
    Task {
      defer { savingQuickNote = false }
      do {
        _ = try await store.perform(.create(.notes, fields: [.content: .string(text)]))
        quickNoteDraft = ""
        quickNoteFocused = keepFocus
        session.scheduleSync()
      } catch { session.error = error.localizedDescription }
    }
  }
}

enum FocusGoalPreset: Int, CaseIterable, Identifiable {
  case stopwatch = 0
  case pomodoro25 = 1500
  case deep45 = 2700
  case hour60 = 3600
  case block90 = 5400

  var id: Int { rawValue }

  var shortLabel: String {
    switch self {
    case .stopwatch: "正向计时"
    case .pomodoro25: "25 分钟"
    case .deep45: "45 分钟"
    case .hour60: "60 分钟"
    case .block90: "90 分钟"
    }
  }

  var menuLabel: String {
    switch self {
    case .stopwatch: "正向计时（不设上限）"
    case .pomodoro25: "25 分钟 · 番茄钟"
    case .deep45: "45 分钟 · 深度专注"
    case .hour60: "60 分钟 · 沉浸一小时"
    case .block90: "90 分钟 · 完整心流周期"
    }
  }

  static func label(for seconds: Int64) -> String {
    if seconds <= 0 { return "正向计时" }
    if let match = Self(rawValue: Int(seconds)) { return match.shortLabel }
    return "\(max(1, seconds / 60)) 分钟"
  }
}

/// Redesigned Focus Pod: supports both Stopwatch & Pomodoro Goal Countdown, today's clickable focus log
/// with 1-click time correction, mid-session task/goal switching, resume-hint bookmarking,
/// and unambiguous distinction between "结束（结算保存）", "完成任务", and "放弃本次计时（作废不保存）".
struct FocusControls: View {
  @Environment(AppSession.self) private var session
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("preferredFocusGoalSeconds") private var preferredGoalSeconds = 0
  @State private var selected = ""
  @State private var showingHintPopover = false
  @State private var showingHistoryPopover = false
  @State private var confirmingDiscard = false
  @State private var showingCountdown = false
  @State private var correctingSession: WorkspaceItem?
  @State private var correctingIntervalID: String?
  @State private var hintDraft = ""
  @State private var hoveringTarget = false
  @State private var hoveringGoal = false

  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var todayString: String { Clock.day() }

  private var todayTodo: [WorkspaceItem] {
    snapshot[.tasks]
      .filter { isTaskDueForToday($0, day: todayString) }
      .sorted(by: taskImportanceOrder)
  }

  private var laterTodo: [WorkspaceItem] {
    snapshot[.tasks]
      .filter { $0.status == "todo" && !isTaskDueForToday($0, day: todayString) }
      .sorted(by: taskImportanceOrder)
  }

  private var current: WorkspaceItem? {
    guard let focus = session.focusStatus else { return nil }
    return snapshot.item(.focusSessions, focus.id)
  }

  private var resolvedIdleTarget: WorkspaceItem? {
    if !selected.isEmpty, let item = snapshot.item(.tasks, selected), item.status == "todo" {
      return item
    }
    return nil
  }

  private struct TodayIntervalEntry: Identifiable {
    let id: String
    let session: WorkspaceItem
    let start: Date
    let end: Date
    let title: String
    let isOpen: Bool
    var minutes: Int { max(1, Int(end.timeIntervalSince(start)) / 60) }
  }

  private var todayIntervals: [TodayIntervalEntry] {
    let startOfToday = Clock.calendar.startOfDay(for: .now)
    guard let endOfToday = Clock.calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
      return []
    }
    var entries: [TodayIntervalEntry] = []
    for interval in snapshot[.focusIntervals] {
      let focusID = interval.fields.text("focus_id")
      guard let focusRow = snapshot.item(.focusSessions, focusID),
        let s = try? Clock.parse(interval.fields.text("started_at"))
      else { continue }
      let rawEnd = interval.fields.text("ended_at")
      let isOpen = rawEnd.isEmpty
      let e = isOpen ? Date.now : ((try? Clock.parse(rawEnd)) ?? s)
      let clippedStart = max(s, startOfToday)
      let clippedEnd = min(e, endOfToday)
      guard clippedEnd > clippedStart else { continue }
      let taskID = focusRow.fields.text("task_id")
      let title =
        taskID.isEmpty ? "自由专注" : (snapshot.item(.tasks, taskID)?.title ?? "自由专注")
      entries.append(
        TodayIntervalEntry(
          id: interval.id,
          session: focusRow,
          start: clippedStart,
          end: clippedEnd,
          title: title,
          isOpen: isOpen
        )
      )
    }
    return entries.sorted { $0.start > $1.start }
  }

  private var todaySummary: (minutes: Int, sessions: Int) {
    let startOfToday = Clock.calendar.startOfDay(for: .now)
    guard let endOfToday = Clock.calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
      return (0, 0)
    }
    var seconds: TimeInterval = 0
    var focusIDs: Set<String> = []
    for interval in snapshot[.focusIntervals] {
      guard let s = try? Clock.parse(interval.fields.text("started_at")) else { continue }
      let rawEnd = interval.fields.text("ended_at")
      let e = rawEnd.isEmpty ? Date.now : ((try? Clock.parse(rawEnd)) ?? s)
      let clippedStart = max(s, startOfToday)
      let clippedEnd = min(e, endOfToday)
      if clippedEnd > clippedStart {
        seconds += clippedEnd.timeIntervalSince(clippedStart)
        focusIDs.insert(interval.fields.text("focus_id"))
      }
    }
    return (Int(seconds) / 60, focusIDs.count)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let current, let focus = session.focusStatus {
        activePod(current: current, focus: focus)
      } else {
        idlePod
      }
      if let notice = session.focusSurfaceNotice {
        HStack(spacing: 6) {
          Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
          Button("重试") { Task { await session.refreshFocusSurfaces() } }.font(.caption)
        }
        .padding(.horizontal, 4)
      }
    }
    .onAppear {
      if selected.isEmpty, let first = todayTodo.first {
        selected = first.id
      }
    }
    .onChange(of: todayTodo.map(\.id)) { _, ids in
      if !selected.isEmpty, snapshot.item(.tasks, selected)?.status != "todo" {
        selected = ids.first ?? ""
      }
    }
    .sheet(item: $correctingSession) { focusItem in
      FocusCorrectionView(focus: focusItem, preferredIntervalID: correctingIntervalID)
    }
    .confirmationDialog(
      "放弃本次专注计时？",
      isPresented: $confirmingDiscard,
      titleVisibility: .visible
    ) {
      if let current {
        Button("放弃并不计入统计", role: .destructive) {
          discardFocus(id: current.id)
        }
      }
    } message: {
      Text("放弃后本次计时将被直接移除，不会保存到今日专注时长与日历中。")
    }
  }

  private var idlePod: some View {
    let summary = todaySummary
    let target = resolvedIdleTarget
    let hint = target?[.resumeHint].string ?? ""
    return ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) {
        idleLeading(summary: summary, target: target, hint: hint)
        Spacer(minLength: 12)
        startFocusButton
      }
      VStack(alignment: .leading, spacing: 10) {
        idleLeading(summary: summary, target: target, hint: hint)
        HStack {
          Spacer(minLength: 0)
          startFocusButton
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
    .background(
      LinearGradient(
        colors: [
          Color.accentColor.opacity(colorScheme == .dark ? 0.07 : 0.04),
          WorkbenchDesign.fieldBackground,
        ],
        startPoint: .leading,
        endPoint: .trailing
      ),
      in: .rect(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(WorkbenchDesign.line, lineWidth: 1)
    }
  }

  private func idleLeading(
    summary: (minutes: Int, sessions: Int),
    target: WorkspaceItem?,
    hint: String
  ) -> some View {
    HStack(spacing: 13) {
      ZStack {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(Color.accentColor.opacity(0.12))
          .frame(width: 40, height: 40)
        Image(systemName: "timer")
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(.tint)
      }

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text("专注心流")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
          if summary.minutes > 0 || summary.sessions > 0 {
            Button {
              showingHistoryPopover.toggle()
            } label: {
              HStack(spacing: 3) {
                Text("今日已专注 \(max(1, summary.minutes)) 分钟 · \(summary.sessions) 段")
                Image(systemName: "chevron.right")
                  .font(.system(size: 8, weight: .bold))
              }
              .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
              .foregroundStyle(.tint)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Color.accentColor.opacity(0.11), in: .capsule)
            }
            .buttonStyle(.plain)
            .help("查看或修正今日专注时段")
            .popover(isPresented: $showingHistoryPopover) {
              todayHistoryPopover
            }
          }
        }

        HStack(spacing: 7) {
          Menu {
            targetMenuItems(activeMode: false, activeTaskID: target?.id)
          } label: {
            HStack(spacing: 5) {
              Image(systemName: target == nil ? "sparkles" : "circle.inset.filled")
                .font(.caption2)
                .foregroundStyle(target == nil ? .secondary : Color.accentColor)
              Text(target?.title ?? "自由专注")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
              Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
              hoveringTarget ? Color.primary.opacity(0.06) : WorkbenchDesign.canvas,
              in: .capsule
            )
            .overlay {
              Capsule().strokeBorder(WorkbenchDesign.line, lineWidth: 1)
            }
            .contentShape(Capsule())
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize(horizontal: false, vertical: true)
          #if os(macOS)
            .onHover { hoveringTarget = $0 }
          #endif

          Menu {
            goalMenuItems(activeFocusID: nil, currentGoal: Int64(preferredGoalSeconds))
          } label: {
            HStack(spacing: 4) {
              Image(systemName: preferredGoalSeconds > 0 ? "hourglass" : "infinity")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(preferredGoalSeconds > 0 ? Color.accentColor : .secondary)
              Text(FocusGoalPreset.label(for: Int64(preferredGoalSeconds)))
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
              Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
              hoveringGoal ? Color.primary.opacity(0.06) : WorkbenchDesign.canvas,
              in: .capsule
            )
            .overlay {
              Capsule().strokeBorder(WorkbenchDesign.line, lineWidth: 1)
            }
            .contentShape(Capsule())
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          #if os(macOS)
            .onHover { hoveringGoal = $0 }
          #endif

          if !hint.isEmpty {
            Label(hint, systemImage: "bookmark.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
    }
  }

  private var todayHistoryPopover: some View {
    let entries = todayIntervals
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("今日专注记录")
          .font(.system(size: 13.5, weight: .medium))
        Spacer()
        Text("点选可修正时长")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      if entries.isEmpty {
        Text("今日暂无已结算时段")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(entries) { entry in
              HStack(spacing: 8) {
                Button {
                  guard !entry.isOpen else { return }
                  showingHistoryPopover = false
                  correctingIntervalID = entry.id
                  correctingSession = entry.session
                } label: {
                  HStack(spacing: 8) {
                    Text(
                      "\(TaskScheduleValues.time(entry.start))–\(entry.isOpen ? "进行中" : TaskScheduleValues.time(entry.end))"
                    )
                    .font(.system(size: 11.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)

                    Text(entry.title)
                      .font(.system(size: 12.5))
                      .foregroundStyle(.primary)
                      .lineLimit(1)
                      .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(entry.minutes)m")
                      .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                      .foregroundStyle(.tint)
                  }
                  .padding(.horizontal, 8)
                  .padding(.vertical, 6)
                  .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 7))
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(entry.isOpen)
              }
            }
          }
        }
        .frame(maxHeight: 210)
      }
    }
    .padding(14)
    .frame(width: 300)
  }

  private var startFocusButton: some View {
    Button {
      let targetID = resolvedIdleTarget?.id
      let goal = preferredGoalSeconds
      session.run {
        _ = try await session.workspace?.perform(.startFocus(taskID: targetID, goalSeconds: goal))
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "play.fill")
          .font(.caption.weight(.bold))
        Text("开始专注")
          .font(.system(size: 13.5, weight: .medium))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 9)
      .background(Color.accentColor, in: .capsule)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("focus.start")
  }

  @ViewBuilder private func goalMenuItems(activeFocusID: String?, currentGoal: Int64) -> some View {
    ForEach(FocusGoalPreset.allCases) { preset in
      Button {
        preferredGoalSeconds = preset.rawValue
        if let activeFocusID {
          session.run {
            _ = try await session.workspace?.perform(
              .updateFocusGoal(id: activeFocusID, goalSeconds: preset.rawValue))
          }
        }
      } label: {
        if Int(currentGoal) == preset.rawValue {
          Label(preset.menuLabel, systemImage: "checkmark")
        } else {
          Text(preset.menuLabel)
        }
      }
    }
  }

  @ViewBuilder private func targetMenuItems(activeMode: Bool, activeTaskID: String?) -> some View {
    Button {
      if activeMode {
        let goal = preferredGoalSeconds
        session.run {
          _ = try await session.workspace?.perform(.startFocus(taskID: nil, goalSeconds: goal))
        }
      } else {
        selected = ""
      }
    } label: {
      Label(
        "自由专注（不绑定任务）",
        systemImage: activeTaskID == nil ? "checkmark" : "sparkles"
      )
    }
    if !todayTodo.isEmpty {
      Section("今日待办") {
        ForEach(todayTodo) { task in
          Button {
            if activeMode {
              let goal = preferredGoalSeconds
              session.run {
                _ = try await session.workspace?.perform(
                  .startFocus(taskID: task.id, goalSeconds: goal))
              }
            } else {
              selected = task.id
            }
          } label: {
            if activeTaskID == task.id {
              Label(task.title, systemImage: "checkmark")
            } else {
              Text(task.title)
            }
          }
        }
      }
    }
    if !laterTodo.isEmpty {
      Section("以后待办") {
        ForEach(laterTodo.prefix(15)) { task in
          Button(task.title) {
            if activeMode {
              let goal = preferredGoalSeconds
              session.run {
                _ = try await session.workspace?.perform(
                  .startFocus(taskID: task.id, goalSeconds: goal))
              }
            } else {
              selected = task.id
            }
          }
        }
      }
    }
  }

  private func activePod(current: WorkspaceItem, focus: FocusPresentation) -> some View {
    let isRunning = current.status == "running"
    let tint: Color = isRunning ? .accentColor : .orange
    let linkedTask = focus.taskID.flatMap { snapshot.item(.tasks, $0) }
    return TimelineView(.periodic(from: .now, by: 1)) { context in
      let progress = focus.timer.progress(at: context.date)
      let remaining = focus.timer.remaining(at: context.date)
      let goalReached = (remaining ?? 1) <= 0 && focus.timer.goalSeconds > 0

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 14) {
          activeIdentity(
            isRunning: isRunning,
            tint: tint,
            focus: focus,
            linkedTask: linkedTask,
            goalReached: goalReached
          )
          Spacer(minLength: 12)
          activeTimerAndControls(
            current: current,
            focus: focus,
            linkedTask: linkedTask,
            isRunning: isRunning,
            tint: tint,
            now: context.date,
            remaining: remaining
          )
        }
        VStack(alignment: .leading, spacing: 10) {
          activeIdentity(
            isRunning: isRunning,
            tint: tint,
            focus: focus,
            linkedTask: linkedTask,
            goalReached: goalReached
          )
          HStack {
            Spacer(minLength: 0)
            activeTimerAndControls(
              current: current,
              focus: focus,
              linkedTask: linkedTask,
              isRunning: isRunning,
              tint: tint,
              now: context.date,
              remaining: remaining
            )
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
      .background(
        LinearGradient(
          colors: [
            tint.opacity(colorScheme == .dark ? 0.16 : 0.085),
            tint.opacity(colorScheme == .dark ? 0.08 : 0.04),
          ],
          startPoint: .leading,
          endPoint: .trailing
        ),
        in: .rect(cornerRadius: 16, style: .continuous)
      )
      .overlay(alignment: .bottomLeading) {
        if let progress {
          GeometryReader { geo in
            Capsule()
              .fill(goalReached ? Color.green.opacity(0.75) : tint.opacity(0.65))
              .frame(width: max(6, geo.size.width * progress), height: 2.5)
              .frame(maxHeight: .infinity, alignment: .bottom)
          }
          .padding(.horizontal, 14)
          .padding(.bottom, 1)
          .allowsHitTesting(false)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(tint.opacity(0.28), lineWidth: 1)
      }
    }
  }

  private func activeIdentity(
    isRunning: Bool,
    tint: Color,
    focus: FocusPresentation,
    linkedTask: WorkspaceItem?,
    goalReached: Bool
  ) -> some View {
    let hint = linkedTask?[.resumeHint].string ?? ""
    return HStack(spacing: 13) {
      ZStack {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(tint.opacity(0.16))
          .frame(width: 40, height: 40)
        Image(systemName: isRunning ? "timer" : "pause.fill")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(tint)
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Circle().fill(tint).frame(width: 6, height: 6)
          Text(isRunning ? "正在专注" : "已暂停")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)

          if focus.timer.goalSeconds > 0 {
            let goalLabel = FocusGoalPreset.label(for: focus.timer.goalSeconds)
            Text(goalReached ? "✓ 已达标 \(goalLabel)" : "目标 \(goalLabel)")
              .font(.system(size: 11, weight: .medium, design: .rounded))
              .foregroundStyle(goalReached ? .green : .secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 1.5)
              .background(
                (goalReached ? Color.green : Color.primary).opacity(0.08),
                in: .capsule
              )
          }
        }

        Menu {
          targetMenuItems(activeMode: true, activeTaskID: linkedTask?.id)
        } label: {
          HStack(spacing: 5) {
            Text(focus.timer.title)
              .font(.system(size: 15.5, weight: .medium))
              .foregroundStyle(.primary)
              .lineLimit(1)
            Image(systemName: "chevron.down")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("切换专注目标")

        if !hint.isEmpty {
          Label(hint, systemImage: "bookmark.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  private func activeTimerAndControls(
    current: WorkspaceItem,
    focus: FocusPresentation,
    linkedTask: WorkspaceItem?,
    isRunning: Bool,
    tint: Color,
    now: Date,
    remaining: Int64?
  ) -> some View {
    HStack(spacing: 8) {
      Group {
        if showingCountdown, let remaining, remaining > 0 {
          Button {
            showingCountdown = false
          } label: {
            HStack(spacing: 3) {
              Text("剩余")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
              Text(FocusTimerState.format(seconds: remaining))
                .font(.system(size: 22, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
            }
          }
          .buttonStyle(.plain)
          .help("点击切换显示已专注时长")
        } else {
          FocusTimerText(state: focus.timer)
            .font(.system(size: 23, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.primary)
            .onTapGesture {
              if focus.timer.goalSeconds > 0, (remaining ?? 0) > 0 {
                showingCountdown.toggle()
              }
            }
            .help(focus.timer.goalSeconds > 0 ? "点击切换剩余倒计时 / 已专注时长" : "已专注时长")
        }
      }
      .padding(.trailing, 4)
      .accessibilityIdentifier("focus.elapsed")

      // 1. Pause / Resume
      Button {
        session.run {
          _ = try await session.workspace?.perform(
            isRunning ? .pauseFocus : .startFocus(taskID: focus.taskID))
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: isRunning ? "pause.fill" : "play.fill")
            .font(.system(size: 10, weight: .bold))
          Text(isRunning ? "暂停" : "继续")
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(isRunning ? Color.primary : Color.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
          isRunning ? Color.primary.opacity(0.08) : Color.accentColor,
          in: .capsule
        )
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("focus.toggle")

      // 2. Finish & Save Focus (Explicit "结束", never an ambiguous "X")
      Button {
        session.run {
          _ = try await session.workspace?.perform(.endFocus(id: current.id, resumeHint: nil))
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "stop.fill")
            .font(.system(size: 9.5, weight: .bold))
          Text("结束")
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.08), in: .capsule)
      }
      .buttonStyle(.plain)
      .help("结算并保存本次专注时长（不勾选完成任务）")
      .accessibilityLabel("结束")
      .accessibilityIdentifier("focus.end")

      // 3. Complete Task & Save Focus (When linked to an open task)
      if let linkedTask, linkedTask.status == "todo" {
        Button {
          session.run {
            _ = try await session.workspace?.perform(
              .update(.tasks, id: linkedTask.id, fields: [.status: .string("done")]))
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .bold))
            Text("完成任务")
              .font(.system(size: 13, weight: .medium))
          }
          .foregroundStyle(.green)
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
          .background(Color.green.opacity(0.13), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("勾选完成该任务，并结算保存本次专注时长")
      }

      // 4. Secondary Actions: Goal Duration, Resume Bookmark, or Discard Session
      Menu {
        Menu("目标时长") {
          goalMenuItems(activeFocusID: current.id, currentGoal: focus.timer.goalSeconds)
        }
        if let linkedTask, linkedTask.status == "todo" {
          Button("记下接续位置并结束…", systemImage: "bookmark") {
            hintDraft = linkedTask[.resumeHint].string
            showingHintPopover = true
          }
        }
        Divider()
        Button("放弃本次计时（不保存）", systemImage: "trash", role: .destructive) {
          if focus.timer.elapsed(at: .now) >= 60 {
            confirmingDiscard = true
          } else {
            discardFocus(id: current.id)
          }
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 30, height: 30)
          .background(Color.primary.opacity(0.06), in: .circle)
          .contentShape(Circle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("更多专注选项（目标时长、接续书签、放弃计时）")
      .popover(isPresented: $showingHintPopover) {
        VStack(alignment: .leading, spacing: 10) {
          Text("记录接续位置并结算专注").font(.system(size: 13.5, weight: .medium))
          TextField("例如：看到第 3 章公式推导…", text: $hintDraft)
            .textFieldStyle(.roundedBorder)
            .onSubmit { endWithHint(focusID: current.id) }
          HStack {
            Spacer()
            Button("取消") { showingHintPopover = false }
            Button("保存并结束") { endWithHint(focusID: current.id) }
              .buttonStyle(.borderedProminent)
          }
        }
        .padding(14)
        .frame(width: 280)
      }
    }
  }

  private func discardFocus(id: String) {
    session.run {
      _ = try await session.workspace?.perform(.delete(.focusSessions, id: id))
    }
  }

  private func endWithHint(focusID: String) {
    let trimmed = hintDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    showingHintPopover = false
    session.run {
      _ = try await session.workspace?.perform(
        .endFocus(id: focusID, resumeHint: trimmed.isEmpty ? nil : trimmed))
    }
  }
}
struct CollectionRoute: Hashable {
  let entity: WorkspaceEntity
  let id: String
}
struct CollectionsView: View {
  let entity: WorkspaceEntity
  @Environment(AppSession.self) private var session
  @Environment(\.openCollection) private var openCollection
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
    return [.learning, .collections].contains(entity) ? treeOrder(rows) : rows
  }
  var body: some View {
    VStack(spacing: 16) {
      HStack(spacing: 16) {
        WorkspaceFilters(
          values: [false, true], selection: $completed, title: { $0 ? "已完结" : "进行中" })
        Spacer(minLength: 0)
        WorkspaceSearch(prompt: "搜索", text: $search).frame(maxWidth: 230)
      }
      if items.isEmpty {
        EmptyState(
          title: !search.isEmpty ? "没有找到匹配内容" : completed ? "暂无已完结卡片" : "暂无内容",
          symbol: entity == .learning ? "book" : "folder",
          detail: completed ? "完结后的卡片会归整到这里。" : "点右上角新建第一张卡片。"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          CollectionBoardLayout {
            ForEach(items) { item in
              CollectionCard(item: item) {
                if let openCollection {
                  openCollection(.init(entity: entity, id: item.id))
                } else {
                  detail = item
                }
              }
            }
          }.padding(.bottom, WorkbenchDesign.Space.group)
        }.scrollDismissesKeyboard(.interactively)
      }
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
  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  var item: WorkspaceItem? { snapshot.item(route.entity, route.id) }
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
                Button("添加随手记", systemImage: "square.and.pencil") { addNote = true }
                Divider()
                if item.status == "active" {
                  Button("暂停排课", systemImage: "pause.circle") {
                    session.run {
                      _ = try await session.workspace?.perform(
                        .update(.courses, id: route.id, fields: [.status: .string("paused")]))
                    }
                  }
                  Button("标记结课", systemImage: "checkmark.circle") {
                    session.run {
                      _ = try await session.workspace?.perform(
                        .update(.courses, id: route.id, fields: [.status: .string("done")]))
                    }
                  }
                } else {
                  Button("恢复排课", systemImage: "play.circle") {
                    session.run {
                      _ = try await session.workspace?.perform(
                        .update(.courses, id: route.id, fields: [.status: .string("active")]))
                    }
                  }
                }
                Divider()
                Button("删除课程…", systemImage: "trash", role: .destructive) { deleting = true }
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
        .confirmationDialog(
          route.entity == .courses ? "删除这门课程？" : "删除这张卡片？",
          isPresented: $deleting,
          titleVisibility: .visible
        ) {
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
    let notes = snapshot[.notes].filter {
      $0[associationField] == .string(item.id) && $0.status != "archived"
    }
    return WorkspaceDetailPage(width: WorkbenchDesign.CollectionLayout.readingWidth) {
      HStack(alignment: .firstTextBaseline, spacing: WorkbenchDesign.Space.medium) {
        Image(systemName: snapshot.collectionSymbol(item))
          .font(.title2)
          .foregroundStyle(
            snapshot.space(for: item).map { spaceColor($0[.color].string) } ?? .secondary
          )
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
      WorkspaceDetailSection(title: "备注") { ItemRemarks(item: item) }
    }.accessibilityIdentifier("collection.detail.content")
  }
  private func coursePage(_ course: WorkspaceItem) -> some View {
    let meetings = courseMeetings(course)
    let tasks = linkedTasks(course)
    let active = tasks.filter { $0.status == "todo" }.sorted(by: taskImportanceOrder)
    let finished = tasks.filter { $0.status != "todo" }.sorted(by: taskImportanceOrder)
    let notes = snapshot[.notes].filter {
      $0[.courseID] == .string(course.id) && $0.status != "archived"
    }
    return WorkspaceDetailPage(width: WorkbenchDesign.CollectionLayout.readingWidth) {
      VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchDesign.Space.medium) {
          Image(systemName: "graduationcap.fill")
            .font(.title2)
            .foregroundStyle(courseHexColor(course[.color].string))
          InlineItemText(course.title) {
            _ = try await session.workspace?.perform(
              .update(.courses, id: course.id, fields: [.title: .string($0)]))
          }.font(WorkbenchDesign.Typography.detailTitle)
        }
        HStack(spacing: WorkbenchDesign.Space.medium) {
          if !course[.teacher].string.isEmpty {
            Label(course[.teacher].string, systemImage: "person")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          if let term = snapshot.item(.semesters, course[.semesterID].string) {
            Text(term.title).font(.caption).foregroundStyle(.secondary)
          }
        }
        CourseScheduleStatus(course: course)
      }.padding(.vertical, WorkbenchDesign.Space.small)

      WorkspaceDetailSection(title: "上课安排", count: meetings.isEmpty ? nil : meetings.count) {
        ForEach(meetings) { meeting in
          HStack(alignment: .top, spacing: WorkbenchDesign.Space.medium) {
            Button {
              editMeeting = meeting
            } label: {
              CourseMeetingSummary(
                meeting: meeting,
                semester: snapshot.item(.semesters, course[.semesterID].string)
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
          if meeting.id != meetings.last?.id { Divider().opacity(0.35) }
        }
        Button {
          addMeeting = true
        } label: {
          Label(
            meetings.isEmpty ? "添加上课安排…" : "继续添加排课…",
            systemImage: "plus.circle"
          )
          .font(.subheadline)
          .foregroundStyle(meetings.isEmpty ? Color.accentColor : .secondary)
          .padding(.top, meetings.isEmpty ? 0 : 4)
        }
        .buttonStyle(.plain)
      }

      WorkspaceDetailSection(title: "待办", count: active.count) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(active) { task in
            ItemRow(item: task, showsAssociation: false)
            if task.id != active.last?.id { Divider().opacity(0.35) }
          }
        }
        CollectionTaskEntry(collection: course, focused: $addingFocused)
        if !finished.isEmpty {
          DisclosureGroup("已结束 · \(finished.count)") {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(finished) { ItemRow(item: $0, showsAssociation: false) }
            }
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.top, WorkbenchDesign.Space.small)
        }
      }

      if !notes.isEmpty {
        WorkspaceDetailSection(title: "随手记", count: notes.count) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(notes) { note in
              ItemRow(item: note, showsAssociation: false)
              if note.id != notes.last?.id { Divider().opacity(0.35) }
            }
          }
        }
      }

      WorkspaceDetailSection(title: "备注") {
        ItemRemarks(item: course)
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
    switch route.entity {
    case .collections: .collectionID
    case .projects: .projectID
    case .courses: .courseID
    default: .learningID
    }
  }
  func linkedTasks(_ item: WorkspaceItem) -> [WorkspaceItem] {
    session.workspace?.snapshot[.tasks].filter { $0[associationField] == .string(item.id) } ?? []
  }
}
