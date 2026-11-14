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
  case today, photos, thoughts, projects, learning, calendar, courses, accounts, settings
  public var id: String { rawValue }
  var title: String {
    switch self {
    case .today: "今日"
    case .photos: "拍照"
    case .thoughts: "思考"
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
    case .photos: "camera"
    case .thoughts: "text.bubble"
    case .projects: "folder"
    case .learning: "book"
    case .courses: "graduationcap"
    case .calendar: "calendar"
    case .accounts: "person.crop.rectangle.stack"
    case .settings: "gearshape"
    }
  }
}
public struct WorkBenchRoot: View {
  @State private var session: AppSession
  @State private var selected: AppModule? = .today
  #if os(iOS)
    private enum PhoneTab: Hashable { case today, photos, thoughts, projects, more }
    @State private var phoneTab = PhoneTab.today
    @State private var focusNavigationID = UUID()
  #endif
  @Environment(\.scenePhase) private var phase
  public init(session: AppSession) { _session = State(initialValue: session) }
  public init(role: AppRole) { _session = State(initialValue: AppSession(role: role)) }
  public var body: some View {
    Group {
      if session.photos == nil {
        startup
      } else if session.role == .photoAssistant {
        assistant
      } else {
        #if os(macOS)
          NavigationSplitView {
            List(selection: $selected) {
              Section {
                ForEach([AppModule.today, .thoughts, .projects, .calendar]) { module in
                  sidebarRow(module)
                }
              }
              Section("规划") {
                ForEach([AppModule.learning, .courses]) { module in sidebarRow(module) }
              }
              Section { sidebarRow(.settings) }
            }.listStyle(.sidebar)
              .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
          } detail: {
            ModuleHost(module: selected ?? .today)
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
            Tab("项目", systemImage: "folder", value: PhoneTab.projects) {
              ModuleHost(module: .projects)
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
    #if os(iOS)
      .onOpenURL { url in
        if session.role == .workbench && url.scheme == "workbench-preview" && url.host == "focus" {
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
  private func sidebarRow(_ module: AppModule) -> some View {
    Label(module.title, systemImage: module.symbol).font(.body).padding(.vertical, 3).tag(module)
  }
  private var startup: some View {
    VStack(spacing: 20) {
      Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(.tint)
      Text("WorkBench").font(.title.bold())
      if session.isLoading {
        ProgressView("正在校验本地数据…")
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
/// Five native tabs avoid UIKit's automatic More controller wrapping another
/// NavigationStack. Overflow modules share one stack and one return path.
#if os(iOS)
  struct MoreModulesView: View {
    @State private var path = NavigationPath()
    var body: some View {
      NavigationStack(path: $path) {
        WorkspaceList {
          Section {
            ForEach([AppModule.learning, .calendar, .courses]) { module in
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
      case .photos: PhotoList(initialStage: photoStage)
      case .thoughts: ThoughtsView()
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
    ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
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
