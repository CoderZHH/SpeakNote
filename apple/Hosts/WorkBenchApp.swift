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
    private let updater = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @State private var focusStatusItem = FocusStatusItemController()
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
