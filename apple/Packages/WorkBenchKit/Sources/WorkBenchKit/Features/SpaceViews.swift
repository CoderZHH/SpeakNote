import SwiftUI

func spaceColor(_ name: String) -> Color {
  switch name {
  case "blue": .blue
  case "teal", "mint": .teal
  case "indigo": .indigo
  case "orange", "yellow": .orange
  case "pink", "red": .pink
  case "green": .green
  default: .accentColor
  }
}

struct SpaceTemplate: Identifiable {
  let id: String
  let title: String
  let symbol: String
  let color: String
}

enum SpaceCatalog {
  static let templates: [SpaceTemplate] = [
    .init(id: "projects", title: "项目", symbol: "folder", color: "blue"),
    .init(id: "learning", title: "学习", symbol: "book", color: "teal"),
    .init(id: "work", title: "工作", symbol: "briefcase", color: "indigo"),
    .init(id: "life", title: "生活", symbol: "leaf", color: "green"),
    .init(id: "creative", title: "创作", symbol: "sparkles", color: "orange"),
    .init(id: "reading", title: "阅读", symbol: "text.book.closed", color: "pink"),
  ]

  static let colors: [(id: String, label: String)] = [
    ("blue", "海蓝"), ("teal", "青绿"), ("indigo", "靛紫"),
    ("green", "森林"), ("orange", "暖橙"), ("pink", "珊瑚"),
  ]

  static let symbols: [String] = [
    "folder", "book", "briefcase", "leaf", "sparkles", "lightbulb",
    "text.book.closed", "graduationcap", "paintbrush", "chevron.left.forwardslash.chevron.right",
    "heart", "house", "cart", "airplane", "figure.run", "music.note", "camera", "archivebox",
  ]
}

struct SpaceEditorSheet: View {
  var space: WorkspaceItem? = nil
  var onSaved: ((String) -> Void)? = nil
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var symbol = "folder"
  @State private var color = "blue"
  @State private var saving = false
  @State private var error: String?
  @FocusState private var titleFocused: Bool

  var body: some View {
    WorkspaceEntrySheet(
      title: space == nil ? "添加空间" : "编辑空间",
      confirmTitle: space == nil ? "添加" : "保存",
      saving: saving,
      canSave: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      cancel: { dismiss() },
      save: save
    ) {
      if space == nil {
        VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
          Text("快速模板").font(.caption).foregroundStyle(.secondary)
          ScrollView(.horizontal) {
            HStack(spacing: WorkbenchDesign.Space.small) {
              ForEach(SpaceCatalog.templates) { template in
                Button {
                  title = template.title
                  symbol = template.symbol
                  color = template.color
                } label: {
                  Label(template.title, systemImage: template.symbol)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(
                      title == template.title && symbol == template.symbol
                        ? spaceColor(template.color) : .primary
                    )
                    .background(
                      title == template.title && symbol == template.symbol
                        ? spaceColor(template.color).opacity(0.14)
                        : WorkbenchDesign.fieldBackground,
                      in: .capsule
                    )
                }.buttonStyle(.plain)
              }
            }
          }.scrollIndicators(.hidden)
        }
      }

      HStack(spacing: WorkbenchDesign.Space.medium) {
        Image(systemName: symbol)
          .font(.title3.weight(.semibold))
          .foregroundStyle(spaceColor(color))
          .frame(width: WorkbenchDesign.controlHeight, height: WorkbenchDesign.controlHeight)
          .background(spaceColor(color).opacity(0.14), in: .rect(cornerRadius: WorkbenchDesign.fieldRadius))
        TextField("空间名称（如：项目、学习、生活…）", text: $title)
          .focused($titleFocused)
          .labelsHidden()
          .workspaceInput(focused: titleFocused)
          .onSubmit { if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { save() } }
          .accessibilityIdentifier("space.title.input")
      }

      VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
        Text("主题色").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: WorkbenchDesign.Space.small) {
          ForEach(SpaceCatalog.colors, id: \.id) { choice in
            Button {
              color = choice.id
            } label: {
              ZStack {
                Circle().fill(spaceColor(choice.id))
                  .frame(width: 22, height: 22)
                if color == choice.id {
                  Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                  Circle().strokeBorder(spaceColor(choice.id), lineWidth: 2)
                    .frame(width: 30, height: 30)
                }
              }
              .frame(width: WorkbenchDesign.ItemActions.swatchTarget, height: WorkbenchDesign.ItemActions.swatchTarget)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("颜色 " + choice.label)
            .accessibilityAddTraits(color == choice.id ? .isSelected : [])
          }
        }
      }

      VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
        Text("图标").font(.caption).foregroundStyle(.secondary)
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
          spacing: 8
        ) {
          ForEach(SpaceCatalog.symbols, id: \.self) { icon in
            Button {
              symbol = icon
            } label: {
              Image(systemName: icon)
                .font(.body.weight(symbol == icon ? .semibold : .regular))
                .foregroundStyle(symbol == icon ? spaceColor(color) : .secondary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(
                  symbol == icon ? spaceColor(color).opacity(0.14) : WorkbenchDesign.fieldBackground,
                  in: .rect(cornerRadius: 8)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("图标 " + icon)
          }
        }
      }

      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .onAppear {
      if let space {
        title = space.title
        symbol = space[.symbol].string.isEmpty ? "folder" : space[.symbol].string
        color = space[.color].string.isEmpty ? "blue" : space[.color].string
      } else {
        titleFocused = true
      }
    }
  }

  private func save() {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !saving, !trimmed.isEmpty, let store = session.workspace else { return }
    saving = true
    error = nil
    Task {
      defer { saving = false }
      do {
        let fields: [ItemField: JSONValue] = [
          .title: .string(trimmed),
          .symbol: .string(symbol),
          .color: .string(color),
        ]
        if let space {
          _ = try await store.perform(.update(.spaces, id: space.id, fields: fields))
          session.scheduleSync()
          onSaved?(space.id)
        } else {
          let result = try await store.perform(.create(.spaces, fields: fields))
          session.scheduleSync()
          if let id = result.id { onSaved?(id) }
        }
        dismiss()
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}

struct SpaceBoardView: View {
  let spaceID: String
  var showsHeaderControls = true
  var onSpaceDeleted: (() -> Void)? = nil
  @Environment(AppSession.self) private var session
  @Environment(\.openCollection) private var openCollection
  @State private var completed = false
  @State private var adding = false
  @State private var editingSpace = false
  @State private var deletingSpace = false
  @State private var search = ""

  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var space: WorkspaceItem? { snapshot.item(.spaces, spaceID) }

  private var targetEntity: WorkspaceEntity {
    guard let space else { return .collections }
    switch space[.legacyEntity].string {
    case "projects": return .projects
    case "learning": return .learning
    default: return .collections
    }
  }

  private func matchingItems(done: Bool) -> [WorkspaceItem] {
    guard let space else { return [] }
    let base: [WorkspaceItem]
    switch targetEntity {
    case .projects:
      base = snapshot[.projects]
    case .learning:
      base = snapshot[.learning]
    default:
      base = snapshot[.collections].filter { $0[.spaceID].string == space.id }
    }
    let filtered = base.filter {
      ($0.status == "done") == done
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
    }.sorted {
      ($0.fields.integer("position"), $0.createdAt, $0.id)
        < ($1.fields.integer("position"), $1.createdAt, $1.id)
    }
    return [.learning, .collections].contains(targetEntity) ? treeOrder(filtered) : filtered
  }

  private var items: [WorkspaceItem] { matchingItems(done: completed) }

  var body: some View {
    Group {
      if let space {
        VStack(spacing: WorkbenchDesign.Space.section) {
          HStack(spacing: WorkbenchDesign.Space.section) {
            WorkspaceFilters(
              values: [false, true],
              selection: $completed,
              title: { $0 ? "已完结" : "进行中" },
              count: { matchingItems(done: $0).count }
            )
            Spacer(minLength: 0)
            WorkspaceSearch(prompt: "搜索", text: $search).frame(maxWidth: 230)
          }
          if items.isEmpty {
            ContentUnavailableView {
              Label(
                !search.isEmpty
                  ? "没有找到匹配卡片"
                  : completed ? "暂无已完结卡片" : "在「\(space.title)」新建第一张卡片",
                systemImage: !search.isEmpty
                  ? "magnifyingglass"
                  : space[.symbol].string.isEmpty ? "folder" : space[.symbol].string
              )
            } description: {
              Text(
                !search.isEmpty
                  ? "试试其他关键词。"
                  : completed
                    ? "标记完结后的卡片会归整到这里。"
                    : "每张卡片都可以直接展开待办、记录想法并添加备注附件。"
              )
            } actions: {
              if search.isEmpty && !completed {
                Button("新建卡片") { adding = true }
                  .buttonStyle(.borderedProminent)
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              CollectionBoardLayout {
                ForEach(items) { item in
                  CollectionCard(item: item) {
                    openCollection?(CollectionRoute(entity: item.entity, id: item.id))
                  }
                }
              }.padding(.bottom, WorkbenchDesign.Space.group)
            }.scrollDismissesKeyboard(.interactively)
          }
        }
        .workspacePage()
        .phoneCreateAction("新建卡片") { adding = true }
        .toolbar {
          if showsHeaderControls {
            ToolbarItem(placement: .primaryAction) {
              Button("新建卡片", systemImage: "plus") { adding = true }
                .accessibilityIdentifier("space.card.new")
            }
            ToolbarItem(placement: .primaryAction) {
              WorkspaceMoreMenu(title: "空间操作") {
                Button("编辑空间…", systemImage: "slider.horizontal.3") { editingSpace = true }
                Button(
                  space.status == "done" ? "恢复到侧边栏" : "归档空间",
                  systemImage: space.status == "done" ? "tray.and.arrow.up" : "archivebox"
                ) {
                  session.run {
                    _ = try await session.workspace?.perform(
                      .update(
                        .spaces, id: space.id,
                        fields: [.status: .string(space.status == "done" ? "active" : "done")]))
                  }
                }
                Divider()
                Button("删除空间…", systemImage: "trash", role: .destructive) {
                  deletingSpace = true
                }
              }
            }
          }
        }
        .sheet(isPresented: $adding) {
          NewItemForm(entity: targetEntity, space: space)
        }
        .sheet(isPresented: $editingSpace) {
          SpaceEditorSheet(space: space)
        }
        .confirmationDialog(
          "删除空间「\(space.title)」？",
          isPresented: $deletingSpace,
          titleVisibility: .visible
        ) {
          Button("删除空间及内部卡片", role: .destructive) {
            session.run {
              _ = try await session.workspace?.perform(.delete(.spaces, id: space.id))
              onSpaceDeleted?()
            }
          }
        } message: {
          Text("空间内的卡片会被移除；原有关联任务将保留在你的待办中，不会被误删。")
        }
      } else {
        EmptyState(title: "空间不存在", symbol: "folder", detail: "请从左侧选择其他空间或新建一个空间。")
      }
    }
  }
}

struct SpacesHubView: View {
  @Environment(AppSession.self) private var session
  @State private var selectedSpaceID: String = ""
  @State private var addingSpace = false
  @State private var editingSpace = false

  private var spaces: [WorkspaceItem] {
    (session.workspace?.snapshot[.spaces] ?? [])
      .filter { $0.status != "done" }
      .sorted { ($0[.position].int, $0.createdAt, $0.id) < ($1[.position].int, $1.createdAt, $1.id) }
  }

  private var currentSpace: WorkspaceItem? {
    spaces.first { $0.id == selectedSpaceID } ?? spaces.first
  }

  var body: some View {
    Group {
      if spaces.isEmpty {
        VStack(spacing: WorkbenchDesign.Space.group) {
          ContentUnavailableView {
            Label("创建你的第一个空间", systemImage: "square.grid.2x2")
          } description: {
            Text("按你的节奏自由添加「项目」「学习」「工作」或「生活」，不再受固定分类限制。")
          } actions: {
            Button("自定义空间…") { addingSpace = true }
              .buttonStyle(.borderedProminent)
          }
          HStack(spacing: WorkbenchDesign.Space.small) {
            ForEach(SpaceCatalog.templates.prefix(4)) { template in
              Button {
                quickCreate(template)
              } label: {
                Label("添加「\(template.title)」", systemImage: template.symbol)
                  .font(.subheadline)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(WorkbenchDesign.fieldBackground, in: .capsule)
              }.buttonStyle(.plain)
            }
          }
        }
        .workspacePage()
      } else if let currentSpace {
        VStack(spacing: 0) {
          HStack(spacing: WorkbenchDesign.Space.small) {
            ScrollView(.horizontal) {
              HStack(spacing: 6) {
                ForEach(spaces) { item in
                  let isSelected = item.id == currentSpace.id
                  Button {
                    selectedSpaceID = item.id
                  } label: {
                    Label(item.title, systemImage: item[.symbol].string.isEmpty ? "folder" : item[.symbol].string)
                      .font(.subheadline.weight(isSelected ? .semibold : .regular))
                      .padding(.horizontal, 12)
                      .padding(.vertical, 7)
                      .foregroundStyle(isSelected ? spaceColor(item[.color].string) : .secondary)
                      .background(
                        isSelected ? spaceColor(item[.color].string).opacity(0.12) : .clear,
                        in: .capsule
                      )
                  }.buttonStyle(.plain)
                }
              }
            }.scrollIndicators(.hidden)
            Button("添加空间", systemImage: "plus.circle") { addingSpace = true }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
          }
          .padding(.horizontal, WorkbenchDesign.pageInset)
          .padding(.top, WorkbenchDesign.Space.small)

          SpaceBoardView(spaceID: currentSpace.id, showsHeaderControls: true) {
            selectedSpaceID = spaces.first { $0.id != currentSpace.id }?.id ?? ""
          }
        }
        .background(WorkbenchDesign.canvas)
      }
    }
    .sheet(isPresented: $addingSpace) {
      SpaceEditorSheet { newID in selectedSpaceID = newID }
    }
    .onChange(of: spaces.map(\.id), initial: true) { _, ids in
      if !ids.contains(selectedSpaceID) { selectedSpaceID = ids.first ?? "" }
    }
  }

  private func quickCreate(_ template: SpaceTemplate) {
    session.run {
      guard let store = session.workspace else { return }
      let result = try await store.perform(
        .create(
          .spaces,
          fields: [
            .title: .string(template.title),
            .symbol: .string(template.symbol),
            .color: .string(template.color),
          ]))
      if let id = result.id { selectedSpaceID = id }
    }
  }
}

enum NoteInboxFilter: String, CaseIterable, Identifiable {
  case inbox = "收件箱"
  case processed = "已转待办"
  case archived = "已归档"
  var id: String { rawValue }
  var statusValue: String {
    switch self {
    case .inbox: "inbox"
    case .processed: "processed"
    case .archived: "archived"
    }
  }
}

struct NotesInboxView: View {
  @Environment(AppSession.self) private var session
  @State private var filter: NoteInboxFilter = .inbox
  @State private var search = ""
  @State private var draft = ""
  @State private var saving = false
  @State private var addingSheet = false
  @FocusState private var composerFocused: Bool

  private var allNotes: [WorkspaceItem] {
    (session.workspace?.snapshot[.notes] ?? []).sorted { $0.createdAt > $1.createdAt }
  }

  private func notes(for target: NoteInboxFilter) -> [WorkspaceItem] {
    allNotes.filter {
      $0.status == target.statusValue
        && (search.isEmpty
          || $0.title.localizedCaseInsensitiveContains(search)
          || $0[.remark].string.localizedCaseInsensitiveContains(search))
    }
  }

  private var visibleNotes: [WorkspaceItem] { notes(for: filter) }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.section) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: WorkbenchDesign.Space.section) {
          WorkspaceFilters(
            values: NoteInboxFilter.allCases,
            selection: $filter,
            title: { $0.rawValue },
            count: { notes(for: $0).count }
          )
          Spacer(minLength: 0)
          WorkspaceSearch(prompt: "搜索随手记", text: $search).frame(maxWidth: 240)
        }
        VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
          WorkspaceFilters(
            values: NoteInboxFilter.allCases,
            selection: $filter,
            title: { $0.rawValue },
            count: { notes(for: $0).count }
          )
          WorkspaceSearch(prompt: "搜索随手记", text: $search)
        }
      }

      if filter == .inbox {
        WorkspaceQuickComposer(
          prompt: "随手记下一闪而过的想法，按回车连输…",
          text: $draft,
          saving: saving,
          submitLabel: "保存随手记",
          inputIdentifier: "notes.quick.input",
          detailLabel: "关联空间或添加附件…",
          onExpandDetail: { addingSheet = true },
          externalFocus: $composerFocused,
          submit: { keepFocus in quickSave(keepFocus: keepFocus) }
        )
      }

      if visibleNotes.isEmpty {
        EmptyState(
          title: filter == .inbox ? "收件箱很干净" : "暂无\(filter.rawValue)内容",
          symbol: filter == .archived ? "archivebox" : "tray",
          detail: filter == .archived
            ? "归档后的随手记会保存在这里，随时可以点右侧菜单恢复。"
            : "临时想法先丢进这里，需要执行时一键加入今日任务。"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        WorkspaceList(inset: 0) {
          ForEach(visibleNotes) { note in
            ItemRow(item: note)
          }
        }
      }
    }
    .workspacePage()
    .phoneCreateAction("记一笔") { addingSheet = true }
    .sheet(isPresented: $addingSheet) {
      NewItemForm(
        entity: .notes,
        initialTitle: draft,
        onCommitted: { draft = "" }
      )
    }
  }

  private func quickSave(keepFocus: Bool = false) {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !saving, !text.isEmpty, let store = session.workspace else { return }
    saving = true
    Task {
      defer { saving = false }
      do {
        _ = try await store.perform(.create(.notes, fields: [.content: .string(text)]))
        draft = ""
        composerFocused = keepFocus
        if filter != .inbox { filter = .inbox }
        session.scheduleSync()
      } catch {
        session.error = error.localizedDescription
      }
    }
  }
}

enum GlobalSearchDestination {
  case task(String)
  case note(String, NoteInboxFilter)
  case thought(String)
  case space(String)
  case collection(CollectionRoute)
}

struct GlobalSearchSheet: View {
  let navigate: (GlobalSearchDestination) -> Void
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var hoveredRowID: String?
  @FocusState private var searchFocused: Bool

  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var matchedTasks: [WorkspaceItem] {
    guard !trimmed.isEmpty else {
      return Array(
        snapshot[.tasks]
          .filter { $0.status == "todo" }
          .sorted(by: taskImportanceOrder)
          .prefix(6)
      )
    }
    return snapshot[.tasks].filter {
      $0.title.localizedCaseInsensitiveContains(trimmed)
        || $0[.notes].string.localizedCaseInsensitiveContains(trimmed)
    }.prefix(10).map { $0 }
  }

  private var matchedCollections: [WorkspaceItem] {
    guard !trimmed.isEmpty else { return [] }
    let all = snapshot[.collections] + snapshot[.projects] + snapshot[.learning] + snapshot[.courses]
    return all.filter {
      $0.title.localizedCaseInsensitiveContains(trimmed)
        || $0[.description].string.localizedCaseInsensitiveContains(trimmed)
        || $0[.teacher].string.localizedCaseInsensitiveContains(trimmed)
    }.prefix(8).map { $0 }
  }

  private var matchedNotes: [WorkspaceItem] {
    guard !trimmed.isEmpty else { return [] }
    return snapshot[.notes].filter {
      $0.title.localizedCaseInsensitiveContains(trimmed)
        || $0[.remark].string.localizedCaseInsensitiveContains(trimmed)
    }.prefix(8).map { $0 }
  }

  private var matchedThoughts: [WorkspaceItem] {
    guard !trimmed.isEmpty else { return [] }
    return snapshot[.reflections].filter {
      $0[.content].string.localizedCaseInsensitiveContains(trimmed)
        || thoughtTags($0).contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }.prefix(8).map { $0 }
  }

  private var hasNoResults: Bool {
    !trimmed.isEmpty
      && matchedTasks.isEmpty
      && matchedCollections.isEmpty
      && matchedNotes.isEmpty
      && matchedThoughts.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.secondary)

        TextField("搜索待办、随手记、思考、空间卡片…", text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 16, weight: .regular))
          .focused($searchFocused)
          #if os(macOS)
            .onExitCommand { dismiss() }
          #endif

        if !query.isEmpty {
          Button {
            query = ""
            searchFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 14))
              .foregroundStyle(.tertiary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("清除关键词")
        }

        Button {
          dismiss()
        } label: {
          Text("ESC")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("关闭")
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Rectangle()
        .fill(WorkbenchDesign.line)
        .frame(height: 0.5)

      if hasNoResults {
        EmptyState(
          title: "未找到「\(trimmed)」相关内容",
          symbol: "magnifyingglass",
          detail: "试试搜索标题关键词或 #标签"
        )
      } else if matchedTasks.isEmpty && trimmed.isEmpty {
        EmptyState(
          title: "输入关键词全局检索",
          symbol: "magnifyingglass",
          detail: "支持搜索任务、随手记、思考长文与所有空间卡片"
        )
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            if !matchedTasks.isEmpty {
              searchGroup(title: trimmed.isEmpty ? "待办速览" : "任务") {
                ForEach(matchedTasks) { task in
                  searchRow(
                    id: "task-" + task.id,
                    symbol: task.status == "done" ? "checkmark.circle.fill" : "circle",
                    symbolTint: task.status == "done" ? .accentColor : .secondary,
                    title: task.title,
                    trailing: task.status == "todo"
                      ? (snapshot.association(task)?.title ?? "")
                      : (task.status == "done" ? "已完成" : "已放弃")
                  ) {
                    dismiss()
                    navigate(.task(task.id))
                  }
                }
              }
            }

            if !matchedCollections.isEmpty {
              searchGroup(title: "空间卡片与课程") {
                ForEach(matchedCollections) { item in
                  searchRow(
                    id: "col-" + item.id,
                    symbol: snapshot.collectionSymbol(item),
                    symbolTint: snapshot.space(for: item).map { spaceColor($0[.color].string) } ?? .secondary,
                    title: item.title,
                    trailing: snapshot.space(for: item)?.title ?? (item.entity == .courses ? "课程" : "")
                  ) {
                    dismiss()
                    navigate(.collection(.init(entity: item.entity, id: item.id)))
                  }
                }
              }
            }

            if !matchedNotes.isEmpty {
              searchGroup(title: "随手记") {
                ForEach(matchedNotes) { note in
                  searchRow(
                    id: "note-" + note.id,
                    symbol: "tray",
                    symbolTint: .secondary,
                    title: note.title,
                    trailing: note.status == "archived" ? "已归档" : ""
                  ) {
                    let bucket: NoteInboxFilter =
                      note.status == "archived"
                      ? .archived : note.status == "processed" ? .processed : .inbox
                    dismiss()
                    navigate(.note(note.id, bucket))
                  }
                }
              }
            }

            if !matchedThoughts.isEmpty {
              searchGroup(title: "思考") {
                ForEach(matchedThoughts) { thought in
                  searchRow(
                    id: "thought-" + thought.id,
                    symbol: "text.bubble",
                    symbolTint: .secondary,
                    title: thoughtTitle(thought[.content].string),
                    trailing: String(thought[.day].string.suffix(5)).replacingOccurrences(of: "-", with: "/")
                  ) {
                    dismiss()
                    navigate(.thought(thought.id))
                  }
                }
              }
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 12)
        }
      }
    }
    .background(WorkbenchDesign.canvas)
    .onAppear { searchFocused = true }
    #if os(macOS)
      .frame(width: 520, height: 370)
    #endif
  }

  private func searchGroup<Rows: View>(title: String, @ViewBuilder rows: () -> Rows) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 11.5, weight: .medium))
        .tracking(0.3)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
      rows()
    }
  }

  private func searchRow(
    id: String,
    symbol: String,
    symbolTint: Color,
    title: String,
    trailing: String,
    action: @escaping () -> Void
  ) -> some View {
    let hovered = hoveredRowID == id
    return Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 13.5, weight: .regular))
          .foregroundStyle(symbolTint)
          .frame(width: 18)

        Text(title)
          .font(.system(size: 14, weight: .regular))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)

        if !trailing.isEmpty {
          Text(trailing)
            .font(.system(size: 12, design: .rounded).monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7.5)
      .background(
        hovered ? Color.primary.opacity(0.055) : .clear,
        in: .rect(cornerRadius: 8, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    #if os(macOS)
      .onHover { isHovering in
        hoveredRowID = isHovering ? id : (hoveredRowID == id ? nil : hoveredRowID)
      }
    #endif
  }
}
