import SwiftUI
import WorkBenchKit
#if os(macOS)
  import Combine
  import Sparkle
#endif

@main struct WorkBenchApp: App {
  #if PHOTO_ASSISTANT
    @State private var session = AppSession(role: .photoAssistant)
  #else
    @State private var session = AppSession(role: .workbench)
  #endif
  #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    private let updater = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @State private var focusStatusItem = FocusStatusItemController(persistent: true)
  #endif
  var body: some Scene {
    WindowGroup("随口记", id: "workbench") {
      WorkBenchRoot(session: session)
        #if os(macOS)
          .frame(minWidth: 390, minHeight: 600)
          .background { FocusStatusItemObserver(controller: focusStatusItem, session: session) }
        #endif
    }
    #if os(macOS)
      .defaultSize(width: 1220, height: 820)
      .defaultLaunchBehavior(.presented)
      .commands {
        CommandGroup(after: .appInfo) {
          CheckForUpdatesButton(updater: updater.updater)
        }
        CommandGroup(replacing: .newItem) {
          Button("新建任务…") {
            openWindow(id: "workbench")
            session.requestedAction = .newTask
          }
          .keyboardShortcut("n", modifiers: [.command])

          Button("新建随手记…") {
            openWindow(id: "workbench")
            session.requestedAction = .newNote
          }
          .keyboardShortcut("n", modifiers: [.command, .shift])

          Button("新建空间…") {
            openWindow(id: "workbench")
            session.requestedAction = .newSpace
          }
          .keyboardShortcut("n", modifiers: [.command, .option])

          Divider()

          Button("全局搜索…") {
            openWindow(id: "workbench")
            session.requestedAction = .openGlobalSearch
          }
          .keyboardShortcut("k", modifiers: [.command])

          Button("打开菜单栏快捷面板") {
            focusStatusItem.togglePanel()
          }
        }
      }
    #endif

  }
}

#if os(macOS)
private struct CheckForUpdatesButton: View {
  let updater: SPUUpdater
  @State private var canCheckForUpdates = false

  var body: some View {
    Button("检查更新…") { updater.checkForUpdates() }
      .disabled(!canCheckForUpdates)
      .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheckForUpdates = $0 }
  }
}
#endif
