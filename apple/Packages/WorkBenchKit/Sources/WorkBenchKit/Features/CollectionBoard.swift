import SwiftUI

/// Stable column assignment avoids moving cards between columns after a checklist changes.
struct CollectionBoardLayout: Layout {
  var spacing: CGFloat = 20
  private func geometry(_ proposal: ProposedViewSize, _ views: Subviews) -> (CGSize, [CGRect]) {
    let width = finiteLayoutWidth(proposal.width, fallback: 800)
    let columns = max(1, min(3, Int((width + spacing) / (340 + spacing))))
    let columnWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
    var heights = [CGFloat](repeating: 0, count: columns)
    var frames: [CGRect] = []
    for index in views.indices {
      let column = index % columns
      let size = views[index].sizeThatFits(.init(width: columnWidth, height: nil))
      let height = finiteLayoutHeight(size.height, fallback: WorkbenchDesign.controlHeight)
      frames.append(
        CGRect(
          x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth,
          height: height))
      heights[column] += height + spacing
    }
    return (.init(width: width, height: max(0, (heights.max() ?? 0) - spacing)), frames)
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    geometry(proposal, subviews).0
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (index, frame) in geometry(proposal, subviews).1.enumerated() {
      subviews[index].place(
        at: .init(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
        proposal: .init(width: frame.width, height: frame.height))
    }
  }
}

struct CollectionCard: View {
  let item: WorkspaceItem
  let open: () -> Void
  @Environment(AppSession.self) private var session
  @State private var showingRemarks = false
  private var linkField: ItemField {
    item.entity == .projects ? .projectID : .learningID
  }
  private var hasRemarks: Bool {
    !item[.description].string.isEmpty
      || session.workspace?.snapshot[.attachments].contains {
        $0.fields[linkField.rawValue] == .string(item.id)
      } == true
  }
  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      HStack(spacing: 8) {
        Image(
          systemName: item.entity == .projects
            ? "folder" : "book"
        ).foregroundStyle(.secondary)
        Button(action: open) {
          Text(item.title).font(.headline).lineLimit(2).frame(
            maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
        Button(
          "备注", systemImage: hasRemarks ? "text.bubble.fill" : "text.bubble"
        ) { showingRemarks.toggle() }.labelStyle(.iconOnly).buttonStyle(.borderless)
          .popover(isPresented: $showingRemarks) {
            ScrollView { ItemRemarks(item: item).padding(WorkbenchDesign.Space.section) }.frame(
              width: 310, height: 240
            )
            .presentationCompactAdaptation(.popover)
          }
        WorkspaceMoreMenu {
          Button("打开详情", systemImage: "arrow.up.right") { open() }
          Button(item.status == "done" ? "恢复进行中" : "标记完结", systemImage: "checkmark") {
            session.run {
              _ = try await session.workspace?.perform(
                .update(
                  item.entity, id: item.id,
                  fields: [.status: .string(item.status == "done" ? "active" : "done")]))
            }
          }
          if item.entity == .learning { TreeMoveMenu(item: item) }
        }
          .accessibilityIdentifier("collection.menu." + item.id)
      }
      CollectionChecklist(item: item)
    }.workspaceCard().fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("collection.card." + item.id)
  }
}
/// Project, learning and course cards share the same checklist and task attachments.
struct CollectionChecklist: View {
  let item: WorkspaceItem
  @Environment(AppSession.self) private var session
  @FocusState private var addingFocused: Bool
  @State private var showingCompleted = false
  private var linkField: ItemField {
    switch item.entity {
    case .projects: .projectID
    case .courses: .courseID
    default: .learningID
    }
  }
  private var tasks: [WorkspaceItem] {
    session.workspace?.snapshot[.tasks].filter { $0[linkField] == .string(item.id) } ?? []
  }
  private var pending: [WorkspaceItem] {
    tasks.filter { $0.status == "todo" }.sorted(by: taskImportanceOrder)
  }
  private var finished: [WorkspaceItem] { tasks.filter { $0.status == "done" } }
  private var lessons: [WorkspaceItem] {
    item.entity == .learning
      ? (session.workspace?.snapshot[.lessons].filter {
        $0[.learningID] == .string(item.id) && $0[.taskID].isNull
      }.sorted { $0[.position].int < $1[.position].int } ?? []) : []
  }
  private var pendingLessons: [WorkspaceItem] { lessons.filter { !$0[.done].bool } }
  private var finishedLessons: [WorkspaceItem] { lessons.filter { $0[.done].bool } }
  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      if !pending.isEmpty || !pendingLessons.isEmpty {
        VStack(spacing: 0) {
          ForEach(pending) { task in
            ItemRow(item: task, showsAssociation: false)
            Divider().opacity(0.4)
          }
          ForEach(pendingLessons) { lesson in
            LessonChecklistRow(lesson: lesson)
            Divider().opacity(0.4)
          }
        }
      }
      CollectionTaskEntry(collection: item, focused: $addingFocused)
      if !finished.isEmpty || !finishedLessons.isEmpty {
        Button {
          showingCompleted.toggle()
        } label: {
          Label("已完成 \(finished.count + finishedLessons.count)", systemImage: "chevron.right").font(
            .caption
          ).foregroundStyle(.secondary)
        }.buttonStyle(.plain)
          .popover(isPresented: $showingCompleted) {
            VStack(alignment: .leading, spacing: 10) {
              Text("已完成").font(.headline)
              ScrollView {
                LazyVStack(spacing: 0) {
                  ForEach(finished) { ItemRow(item: $0, showsAssociation: false) }
                  ForEach(finishedLessons) { LessonChecklistRow(lesson: $0) }
                }
              }
            }.padding(WorkbenchDesign.Space.section).frame(width: 330, height: 320)
              .presentationCompactAdaptation(.popover)
          }
      }
    }
  }
}
/// The collection owns the association; adding never needs a second navigation layer.
struct CollectionTaskEntry: View {
  let collection: WorkspaceItem
  var focused: FocusState<Bool>.Binding
  @Environment(AppSession.self) private var session
  @State private var title = ""
  @State private var saving = false
  @State private var error: String?
  private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
      WorkspaceComposerLayout {
        VStack(spacing: 0) {
          TextField("添加待办…", text: $title, axis: .vertical).lineLimit(1...8)
            .focused(focused).workspaceInput(focused: focused.wrappedValue)
            .workspaceKeyboardDone(when: focused.wrappedValue) { focused.wrappedValue = false }
            .accessibilityIdentifier("collection.task.input." + collection.id)
        }.accessibilityElement(children: .contain)
          .accessibilityIdentifier("collection.task.field." + collection.id)
        Button(action: save) {
          if saving { ProgressView().controlSize(.small) } else { Image(systemName: "plus") }
        }.buttonStyle(WorkspaceSubmitButtonStyle()).disabled(saving || !canSave)
          .accessibilityLabel("添加到" + collection.title)
          .accessibilityIdentifier("collection.task.add." + collection.id)
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
  }
  private func save() {
    guard !saving, canSave, let store = session.workspace else { return }
    let value = title
    let field: ItemField =
      collection.entity == .projects
      ? .projectID
      : collection.entity == .courses ? .courseID : .learningID
    saving = true
    error = nil
    Task {
      defer { saving = false }
      do {
        _ = try await store.perform(
          .create(.tasks, fields: [.title: .string(value), field: .string(collection.id)]))
        if title == value {
          focused.wrappedValue = false
          title = ""
        }
        session.scheduleSync()
      } catch { self.error = error.localizedDescription }
    }
  }
}
struct LessonChecklistRow: View {
  let lesson: WorkspaceItem
  @Environment(AppSession.self) private var session
  var body: some View {
    HStack(spacing: 8) {
      Button {
        session.run {
          _ = try await session.workspace?.perform(
            .update(.lessons, id: lesson.id, fields: [.done: .integer(lesson[.done].bool ? 0 : 1)]))
        }
      } label: {
        Image(systemName: lesson[.done].bool ? "checkmark.circle.fill" : "circle").font(
          .system(size: 17, weight: .light))
      }.buttonStyle(.plain)
      InlineItemText(lesson.title) {
        _ = try await session.workspace?.perform(
          .update(.lessons, id: lesson.id, fields: [.title: .string($0)]))
      }
      WorkspaceMoreMenu(title: "步骤操作") {
        Button("安排今日", systemImage: "sun.max") {
          session.run {
            _ = try await session.workspace?.perform(
              .scheduleLesson(id: lesson.id, plannedDate: Clock.day()))
          }
        }
        TreeMoveMenu(item: lesson)
      }
    }.padding(.vertical, 8)
  }
}
