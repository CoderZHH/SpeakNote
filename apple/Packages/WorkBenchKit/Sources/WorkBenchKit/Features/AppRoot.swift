import SwiftUI
import UniformTypeIdentifiers

private struct OpenCollectionKey: EnvironmentKey {
  static let defaultValue: (@MainActor @Sendable (CollectionRoute) -> Void)? = nil
}
extension EnvironmentValues {
  var openCollection: (@MainActor @Sendable (CollectionRoute) -> Void)? {
    get { self[OpenCollectionKey.self] }
    set { self[OpenCollectionKey.self] = newValue }
  }
}

public enum AppModule: String, CaseIterable, Identifiable {
  case today, notes, photos, thoughts, spaces, projects, learning, calendar, courses, accounts,
    settings
  public var id: String { rawValue }
  var title: String {
    switch self {
    case .today: "今日"
    case .notes: "随手记"
    case .photos: "拍照"
    case .thoughts: "思考"
    case .spaces: "空间"
    case .projects: "项目"
    case .learning: "学习"
    case .courses: "课程"
    case .calendar: "日历"
    case .accounts: "账号"
    case .settings: "设置"
    }
  }
  var symbol: String {
    switch self {
    case .today: "sun.max"
    case .notes: "tray"
    case .photos: "camera"
    case .thoughts: "text.bubble"
    case .spaces: "square.grid.2x2"
    case .projects: "folder"
    case .learning: "book"
    case .courses: "graduationcap"
    case .calendar: "calendar"
    case .accounts: "person.crop.rectangle.stack"
    case .settings: "gearshape"
    }
  }
}

enum SidebarDestination: Hashable {
  case module(AppModule)
  case space(String)
}

public struct WorkBenchRoot: View {
  @State private var session: AppSession
  #if os(macOS)
    @State private var selected: SidebarDestination? = .module(.today)
    @AppStorage("didFinishWeChatSetup") private var didFinishWeChatSetup = false
    @AppStorage("showCoursesModule") private var showCoursesModule = true
    @State private var presentingOnboarding = true
    @State private var enteredWorkspace = false
    @State private var showingWeChat = false
    @State private var showingSearch = false
    @State private var addingSpace = false
    @State private var editingSpace: WorkspaceItem?
    @State private var deletingSpace: WorkspaceItem?
    @State private var quickCreateEntity: WorkspaceEntity?
    @State private var revealedTask: String?
    @State private var pendingCollectionRoute: CollectionRoute?
    @State private var pendingThoughtRoute: ThoughtRoute?
  #endif
  #if os(iOS)
    private enum PhoneTab: Hashable { case today, photos, thoughts, spaces, more }
    @State private var phoneTab = PhoneTab.today
    @State private var focusNavigationID = UUID()
  #endif
  @Environment(\.scenePhase) private var phase
  public init(session: AppSession) { _session = State(initialValue: session) }
  public init(role: AppRole) { _session = State(initialValue: AppSession(role: role)) }

  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var activeSpaces: [WorkspaceItem] {
    snapshot[.spaces]
      .filter { $0.status != "done" }
      .sorted { ($0[.position].int, $0.createdAt, $0.id) < ($1[.position].int, $1.createdAt, $1.id) }
  }
  private var archivedSpaces: [WorkspaceItem] {
    snapshot[.spaces]
      .filter { $0.status == "done" }
      .sorted { ($0[.position].int, $0.createdAt, $0.id) < ($1[.position].int, $1.createdAt, $1.id) }
  }

  public var body: some View {
    Group {
      if session.photos == nil {
        startup
      } else if session.role == .photoAssistant {
        assistant
      } else {
        #if os(macOS)
          if didFinishWeChatSetup || enteredWorkspace {
            macWorkspace
          } else {
            onboardingHost
          }
        #else
          TabView(selection: $phoneTab) {
            Tab("今日", systemImage: "sun.max", value: PhoneTab.today) {
              ModuleHost(module: .today).id(focusNavigationID)
            }
            Tab("拍照", systemImage: "camera", value: PhoneTab.photos) { ModuleHost(module: .photos) }
            Tab("思考", systemImage: "text.bubble", value: PhoneTab.thoughts) {
              ModuleHost(module: .thoughts)
            }
            Tab("空间", systemImage: "square.grid.2x2", value: PhoneTab.spaces) {
              ModuleHost(module: .spaces)
            }
            Tab("更多", systemImage: "ellipsis", value: PhoneTab.more) { MoreModulesView() }
          }
        #endif
      }
    }
    .environment(session)
    .task {
      await session.start()
      if session.photos != nil { await session.sync() }
    }
    .onChange(of: phase) { _, value in
      Task {
        if let store = session.workspace { await session.thoughtEditing.flushAll(store: store) }
        if value == .active {
          await session.refreshFocusSurfaces()
          await session.refreshWorkspaceReminders(force: true)
          await session.sync()
        }
      }
    }
    #if os(macOS)
      .onChange(of: session.requestedAction) { _, action in
        guard let action else { return }
        session.requestedAction = nil
        handleRequestedAction(action)
      }
    #endif
    #if os(iOS)
      .onOpenURL { url in
        if session.role == .workbench && url.scheme == "speaknote" && url.host == "focus" {
          focusNavigationID = UUID()
          phoneTab = .today
        }
      }
    #endif
    .alert(
      "操作未完成",
      isPresented: Binding(
        get: { session.error != nil && session.photos != nil },
        set: { if !$0 { session.error = nil } })
    ) {
      Button("好", role: .cancel) { session.error = nil }
    } message: {
      Text(session.error ?? "")
    }
  }

  #if os(macOS)
    private var canEnterWorkspace: Bool {
      let assistant = session.weChatAssistant
      return assistant.ready && assistant.connected && assistant.hasKey && !assistant.verifying
    }

    private var onboardingHost: some View {
      VStack(spacing: 16) {
        SpeakNoteLogoBadge(size: 56)
        Text("随口记")
          .font(.system(size: 20, weight: .medium))
          .tracking(0.5)
        Button("进入工作台") { finishOnboarding() }
          .buttonStyle(.bordered)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(WorkbenchDesign.canvas)
      .onAppear {
        if canEnterWorkspace { finishOnboarding() }
      }
      .sheet(isPresented: $presentingOnboarding, onDismiss: finishOnboarding) {
        WeChatAssistantView(
          isOnboarding: true,
          showTask: { id in
            revealWeChatTask(id)
            presentingOnboarding = false
          },
          skipOnboarding: { presentingOnboarding = false }
        )
        .environment(session)
        .interactiveDismissDisabled()
      }
    }

    private func finishOnboarding() {
      enteredWorkspace = true
      didFinishWeChatSetup = true
    }

    private func handleRequestedAction(_ action: WorkspaceUIAction) {
      if !didFinishWeChatSetup && !enteredWorkspace {
        finishOnboarding()
      }
      switch action {
      case .openToday:
        selected = .module(.today)
      case .openNotes:
        selected = .module(.notes)
      case .openGlobalSearch:
        showingSearch = true
      case .newTask:
        quickCreateEntity = .tasks
      case .newNote:
        quickCreateEntity = .notes
      case .newSpace:
        addingSpace = true
      }
    }

    private var macWorkspace: some View {
      NavigationSplitView {
        List(selection: $selected) {
          Section {
            ForEach([AppModule.today, .notes, .thoughts, .calendar]) { module in
              sidebarModuleRow(module)
            }
            if showCoursesModule {
              sidebarModuleRow(.courses)
                .contextMenu {
                  Button("在侧边栏隐藏「课程」", systemImage: "eye.slash") {
                    showCoursesModule = false
                    if selected == .module(.courses) { selected = .module(.today) }
                  }
                }
            }
          }

          Section("空间") {
            ForEach(activeSpaces) { space in
              sidebarSpaceRow(space)
            }
            if activeSpaces.isEmpty {
              Button {
                addingSpace = true
              } label: {
                Text("点击下方「新建空间」添加分类")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("sidebar.space.add.empty")
            }
          }

          Section {
            Button {
              showingWeChat = true
            } label: {
              HStack {
                Label {
                  Text("微信助手").foregroundStyle(.primary)
                } icon: {
                  Image(systemName: "bubble.left.and.bubble.right")
                }
                Spacer()
                Circle()
                  .fill(weChatStatusColor)
                  .frame(width: 7, height: 7)
                  .help(weChatStatusText)
              }
              .font(.body)
              .padding(.vertical, 3)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("wechat.assistant.open")

            sidebarModuleRow(.settings)
          }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          sidebarFooter
        }
        .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 250)
      } detail: {
        DesktopDetailHost(
          destination: selected ?? .module(.today),
          pendingCollection: $pendingCollectionRoute,
          pendingThought: $pendingThoughtRoute,
          onSpaceDeleted: { selected = .module(.today) }
        )
        .environment(\.revealedWeChatTask, revealedTask)
      }
      .sheet(isPresented: $showingWeChat) {
        WeChatAssistantView(isOnboarding: false, showTask: revealWeChatTask)
          .environment(session)
      }
      .sheet(isPresented: $addingSpace) {
        SpaceEditorSheet { createdID in
          selected = .space(createdID)
        }
      }
      .sheet(item: $editingSpace) { space in
        SpaceEditorSheet(space: space)
      }
      .sheet(
        isPresented: Binding(
          get: { quickCreateEntity != nil },
          set: { if !$0 { quickCreateEntity = nil } }
        )
      ) {
        if let entity = quickCreateEntity {
          NewItemForm(entity: entity)
        }
      }
      .sheet(isPresented: $showingSearch) {
        GlobalSearchSheet { dest in
          navigateSearch(dest)
        }
      }
      .confirmationDialog(
        "删除空间「\(deletingSpace?.title ?? "")」？",
        isPresented: Binding(
          get: { deletingSpace != nil },
          set: { if !$0 { deletingSpace = nil } }
        ),
        titleVisibility: .visible
      ) {
        if let target = deletingSpace {
          Button("删除空间及内部卡片", role: .destructive) {
            let deletedID = target.id
            deletingSpace = nil
            session.run {
              _ = try await session.workspace?.perform(.delete(.spaces, id: deletedID))
              if selected == .space(deletedID) { selected = .module(.today) }
            }
          }
        }
      } message: {
        Text("空间内的卡片会被移除；关联的任务仍保留在你的待办中。")
      }
    }

    private var weChatStatusColor: Color {
      let assistant = session.weChatAssistant
      if assistant.online { return .green }
      if assistant.running { return .orange }
      return .secondary.opacity(0.45)
    }

    private var weChatStatusText: String {
      let assistant = session.weChatAssistant
      if assistant.online { return "微信助手在线" }
      if assistant.running { return "微信助手正在连接" }
      return "微信助手未启动"
    }

    private var sidebarFooter: some View {
      VStack(spacing: 0) {
        Divider().opacity(0.45)
        HStack(spacing: 8) {
          Button {
            addingSpace = true
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "plus.circle")
              Text("新建空间")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("新建自定义空间 (⌘⌥N)")
          .accessibilityIdentifier("sidebar.space.add")

          Spacer(minLength: 0)

          if !archivedSpaces.isEmpty {
            Menu {
              ForEach(archivedSpaces) { space in
                Button("恢复「\(space.title)」", systemImage: space[.symbol].string) {
                  session.run {
                    _ = try await session.workspace?.perform(
                      .update(.spaces, id: space.id, fields: [.status: .string("active")]))
                  }
                }
              }
            } label: {
              Image(systemName: "archivebox")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("查看与恢复已归档空间 (\(archivedSpaces.count))")
          }

          Button {
            showingSearch = true
          } label: {
            Image(systemName: "magnifyingglass")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(width: 26, height: 26)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("全局搜索 (⌘K)")
          .accessibilityIdentifier("sidebar.search.open")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
      }
    }

    private func sidebarModuleRow(_ module: AppModule) -> some View {
      Label {
        Text(module.title).foregroundStyle(.primary)
      } icon: {
        Image(systemName: module.symbol)
      }
      .font(.body)
      .padding(.vertical, 3)
      .tag(SidebarDestination.module(module))
    }

    private func sidebarSpaceRow(_ space: WorkspaceItem) -> some View {
      let icon = space[.symbol].string.isEmpty ? "folder" : space[.symbol].string
      let tint = spaceColor(space[.color].string)
      return Label {
        Text(space.title).foregroundStyle(.primary)
      } icon: {
        Image(systemName: icon).foregroundStyle(tint)
      }
      .font(.body)
      .padding(.vertical, 3)
      .tag(SidebarDestination.space(space.id))
      .contextMenu {
        Button("编辑空间…", systemImage: "slider.horizontal.3") { editingSpace = space }
        if activeSpaces.count > 1 {
          if let index = activeSpaces.firstIndex(where: { $0.id == space.id }) {
            if index > 0 {
              Button("上移", systemImage: "arrow.up") {
                moveSpace(space, target: activeSpaces[index - 1], placement: .before)
              }
            }
            if index + 1 < activeSpaces.count {
              Button("下移", systemImage: "arrow.down") {
                moveSpace(space, target: activeSpaces[index + 1], placement: .after)
              }
            }
          }
        }
        Button("归档空间", systemImage: "archivebox") {
          session.run {
            _ = try await session.workspace?.perform(
              .update(.spaces, id: space.id, fields: [.status: .string("done")]))
            if selected == .space(space.id) { selected = .module(.today) }
          }
        }
        Divider()
        Button("删除空间…", systemImage: "trash", role: .destructive) {
          deletingSpace = space
        }
      }
    }

    private func moveSpace(_ space: WorkspaceItem, target: WorkspaceItem, placement: MovePlacement) {
      session.run {
        _ = try await session.workspace?.perform(
          .move(.spaces, id: space.id, targetEntity: .spaces, targetID: target.id, placement: placement)
        )
      }
    }

    private func navigateSearch(_ dest: GlobalSearchDestination) {
      switch dest {
      case .task(let id):
        revealWeChatTask(id)
      case .note:
        selected = .module(.notes)
      case .thought(let id):
        selected = .module(.thoughts)
        pendingThoughtRoute = ThoughtRoute(id: id)
      case .space(let id):
        selected = .space(id)
      case .collection(let route):
        if let item = snapshot.item(route.entity, route.id),
          let parentSpace = snapshot.space(for: item)
        {
          selected = .space(parentSpace.id)
        } else {
          selected = .module(.today)
        }
        pendingCollectionRoute = route
      }
    }

    private func revealWeChatTask(_ id: String) {
      selected = .module(.today)
      revealedTask = id
    }
  #endif

  private var startup: some View {
    VStack(spacing: 18) {
      SpeakNoteLogoBadge(size: 64)
      Text("随口记")
        .font(.system(size: 22, weight: .medium))
        .tracking(0.6)
      if session.isLoading {
        ProgressView("正在校验本地数据…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else if let error = session.error {
        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        Button("重试") { Task { await session.start() } }
      }
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var assistant: some View {
    TabView {
      Tab("订单", systemImage: "list.bullet.rectangle") { ModuleHost(module: .photos) }
      Tab("拍摄", systemImage: "camera") {
        ModuleHost(module: .photos, photoStage: .output)
      }
      Tab("设置", systemImage: "gearshape") { ModuleHost(module: .settings) }
    }
  }
}

#if os(macOS)
  private struct DesktopDetailHost: View {
    let destination: SidebarDestination
    @Binding var pendingCollection: CollectionRoute?
    @Binding var pendingThought: ThoughtRoute?
    var onSpaceDeleted: () -> Void
    @Environment(AppSession.self) private var session
    @State private var path = NavigationPath()

    private var navTitle: String {
      switch destination {
      case .module(let module):
        return module.title
      case .space(let id):
        return session.workspace?.snapshot.item(.spaces, id)?.title ?? "空间"
      }
    }

    var body: some View {
      NavigationStack(path: $path) {
        Group {
          switch destination {
          case .module(let module):
            ModuleContent(module: module)
          case .space(let id):
            SpaceBoardView(spaceID: id, onSpaceDeleted: onSpaceDeleted)
          }
        }
        .navigationDestination(for: CollectionRoute.self) {
          CollectionDetail(route: $0)
        }
        .navigationDestination(for: ThoughtRoute.self) {
          ThoughtEditor(id: $0.id, initialTags: $0.initialTags)
        }
        .navigationTitle(navTitle)
      }
      .environment(\.openCollection, { path.append($0) })
      .onChange(of: destination) { _, _ in
        path = NavigationPath()
      }
      .onChange(of: pendingCollection) { _, route in
        guard let route else { return }
        pendingCollection = nil
        Task { @MainActor in
          path.append(route)
        }
      }
      .onChange(of: pendingThought) { _, route in
        guard let route else { return }
        pendingThought = nil
        Task { @MainActor in
          path.append(route)
        }
      }
    }
  }
#endif

/// Five native tabs avoid UIKit's automatic More controller wrapping another
/// NavigationStack. Overflow modules share one stack and one return path.
#if os(iOS)
  struct MoreModulesView: View {
    @State private var path = NavigationPath()
    var body: some View {
      NavigationStack(path: $path) {
        WorkspaceList {
          Section {
            ForEach([AppModule.notes, .calendar, .courses]) { module in
              NavigationLink(value: module) { Label(module.title, systemImage: module.symbol) }
            }
          }
          Section {
            ForEach([AppModule.accounts, .settings]) { module in
              NavigationLink(value: module) { Label(module.title, systemImage: module.symbol) }
            }
          }
        }.navigationDestination(for: CollectionRoute.self) { CollectionDetail(route: $0) }
          .navigationTitle("更多").navigationBarTitleDisplayMode(.inline)
          .navigationDestination(for: AppModule.self) { module in
            ModuleContent(module: module).navigationTitle(module.title)
              .navigationBarTitleDisplayMode(.inline)
          }
      }.environment(\.openCollection, { path.append($0) })
    }
  }
#endif

struct ModuleHost: View {
  let module: AppModule
  var photoStage: PhotoStage? = nil
  @State private var path = NavigationPath()
  var body: some View {
    NavigationStack(path: $path) {
      ModuleContent(module: module, photoStage: photoStage)
        .navigationDestination(for: CollectionRoute.self) {
          CollectionDetail(route: $0)
        }
        #if os(iOS)
          .navigationTitle(module == .settings ? module.title : "")
          .navigationBarTitleDisplayMode(.inline)
          .toolbarVisibility(
            module != .settings && path.isEmpty ? .hidden : .visible, for: .navigationBar)
        #else
          .navigationTitle(module.title)
        #endif
    }.environment(\.openCollection, { path.append($0) })
  }
}

struct ModuleContent: View {
  let module: AppModule
  var photoStage: PhotoStage? = nil
  var body: some View {
    Group {
      switch module {
      case .today: TodayView()
      case .notes: NotesInboxView()
      case .photos: PhotoList(initialStage: photoStage)
      case .thoughts: ThoughtsView()
      case .spaces: SpacesHubView()
      case .projects: CollectionsView(entity: .projects)
      case .learning: CollectionsView(entity: .learning)
      case .courses: CoursesView()
      case .calendar: CalendarView()
      case .accounts: AccountsView()
      case .settings: SettingsView()
      }
    }
  }
}

extension View {
  func readablePage() -> some View {
    self.frame(maxWidth: WorkbenchDesign.readingWidth).frame(maxWidth: .infinity)
  }
}

struct EmptyState: View {
  let title: String
  let symbol: String
  let detail: String
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 26, weight: .light))
        .foregroundStyle(.tertiary)
        .padding(.bottom, 2)
      Text(title)
        .font(.system(size: 15, weight: .medium))
        .tracking(0.2)
        .foregroundStyle(.secondary)
      if !detail.isEmpty {
        Text(detail)
          .font(.system(size: 13))
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 280)
          .lineSpacing(3)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

func importanceColor(_ level: Int) -> Color {
  switch level {
  case 2: .teal
  case 3: .blue
  case 4: .orange
  case 5: .red
  default: .secondary
  }
}
