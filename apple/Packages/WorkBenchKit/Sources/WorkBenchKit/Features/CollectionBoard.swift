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
  @State private var addingNote = false
  @State private var deleting = false
  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var linkField: ItemField {
    switch item.entity {
    case .collections: .collectionID
    case .projects: .projectID
    default: .learningID
    }
  }
  private var hasRemarks: Bool {
    !item[.description].string.isEmpty
      || snapshot[.attachments].contains {
        $0.fields[linkField.rawValue] == .string(item.id)
      }
  }
  private var symbolColor: Color {
    if let parent = snapshot.space(for: item), !parent[.color].string.isEmpty {
      return spaceColor(parent[.color].string)
    }
    return .accentColor
  }
  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      WorkspaceCardHeader(
        symbol: snapshot.collectionSymbol(item),
        symbolColor: symbolColor,
        title: item.title,
        open: open,
        hasRemarks: hasRemarks,
        showingRemarks: $showingRemarks,
        menuIdentifier: "collection.menu." + item.id
      ) {
        ItemRemarks(item: item)
      } menuItems: {
        Button("打开详情", systemImage: "arrow.up.right") { open() }
        Button("添加随手记", systemImage: "square.and.pencil") { addingNote = true }
        Button(item.status == "done" ? "恢复进行中" : "标记完结", systemImage: "checkmark") {
          session.run {
            _ = try await session.workspace?.perform(
              .update(
                item.entity, id: item.id,
                fields: [.status: .string(item.status == "done" ? "active" : "done")]))
          }
        }
        if [.learning, .collections, .projects].contains(item.entity) {
          TreeMoveMenu(item: item)
        }
        Divider()
        Button("删除…", systemImage: "trash", role: .destructive) { deleting = true }
      }
      Divider().opacity(0.45)
      CollectionChecklist(item: item)
    }.workspaceCard().fixedSize(horizontal: false, vertical: true)
      .sheet(isPresented: $addingNote) { NewItemForm(entity: .notes, association: item) }
      .confirmationDialog("删除「\(item.title)」？", isPresented: $deleting, titleVisibility: .visible) {
        Button("删除", role: .destructive) {
          session.run {
            _ = try await session.workspace?.perform(.delete(item.entity, id: item.id))
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("collection.card." + item.id)
  }
}
/// Project, learning, custom collection and course cards share the same checklist and task attachments.
struct CollectionChecklist: View {
  let item: WorkspaceItem
  @Environment(AppSession.self) private var session
  @FocusState private var addingFocused: Bool
  @State private var showingCompleted = false
  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var linkField: ItemField {
    switch item.entity {
    case .collections: .collectionID
    case .projects: .projectID
    case .courses: .courseID
    default: .learningID
    }
  }
  private var tasks: [WorkspaceItem] {
    snapshot[.tasks].filter { $0[linkField] == .string(item.id) }
  }
  private var pending: [WorkspaceItem] {
    tasks.filter { $0.status == "todo" }.sorted(by: taskImportanceOrder)
  }
  private var finished: [WorkspaceItem] { tasks.filter { $0.status == "done" } }
  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      if !pending.isEmpty {
        VStack(spacing: 0) {
          ForEach(pending) { task in
            ItemRow(item: task, showsAssociation: false)
            Divider().opacity(0.4)
          }
        }
      }
      CollectionTaskEntry(collection: item, focused: $addingFocused)
      if !finished.isEmpty {
        Button {
          showingCompleted.toggle()
        } label: {
          Label("已完成 \(finished.count)", systemImage: "chevron.right").font(
            .caption
          ).foregroundStyle(.secondary)
        }.buttonStyle(.plain)
          .popover(isPresented: $showingCompleted) {
            VStack(alignment: .leading, spacing: 10) {
              Text("已完成").font(.headline)
              ScrollView {
                LazyVStack(spacing: 0) {
                  ForEach(finished) { ItemRow(item: $0, showsAssociation: false) }
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
  @State private var expandingDetail = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
      WorkspaceQuickComposer(
        prompt: "添加待办…",
        text: $title,
        saving: saving,
        submitLabel: "添加到" + collection.title,
        inputIdentifier: "collection.task.input." + collection.id,
        fieldIdentifier: "collection.task.field." + collection.id,
        submitIdentifier: "collection.task.add." + collection.id,
        detailLabel: "设置时间、优先级或附件…",
        onExpandDetail: { expandingDetail = true },
        externalFocus: focused,
        submit: { keepFocus in save(keepFocus: keepFocus) }
      )
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .sheet(isPresented: $expandingDetail) {
      NewItemForm(
        entity: .tasks,
        association: collection,
        initialTitle: title,
        onCommitted: { title = "" }
      )
    }
  }
  private func save(keepFocus: Bool = false) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !saving, !trimmed.isEmpty, let store = session.workspace else { return }
    let value = trimmed
    let field: ItemField =
      switch collection.entity {
      case .collections: .collectionID
      case .projects: .projectID
      case .courses: .courseID
      default: .learningID
      }
    saving = true
    error = nil
    Task {
      defer { saving = false }
      do {
        _ = try await store.perform(
          .create(.tasks, fields: [.title: .string(value), field: .string(collection.id)]))
        title = ""
        if keepFocus {
          focused.wrappedValue = true
        } else {
          focused.wrappedValue = false
        }
        session.scheduleSync()
      } catch { self.error = error.localizedDescription }
    }
  }
}
