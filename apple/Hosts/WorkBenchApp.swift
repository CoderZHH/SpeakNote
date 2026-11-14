import SwiftUI
import WorkBenchKit

@main struct WorkBenchApp: App {
  #if PHOTO_ASSISTANT
    @State private var session = AppSession(role: .photoAssistant)
  #else
    @State private var session = AppSession(role: .workbench)
  #endif
  #if os(macOS)
    @State private var focusStatusItem = FocusStatusItemController()
  #endif
  var body: some Scene {
    WindowGroup("WorkBench", id: "workbench") {
      WorkBenchRoot(session: session)
        #if os(macOS)
          .frame(minWidth: 390, minHeight: 600)
          .background { FocusStatusItemObserver(controller: focusStatusItem, session: session) }
        #endif
    }
    #if os(macOS)
      .defaultSize(width: 1220, height: 820)
      .defaultLaunchBehavior(.presented)
    #endif

  }
}
