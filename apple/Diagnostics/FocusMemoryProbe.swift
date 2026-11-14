import SwiftUI
import WorkBenchKit

@main struct Probe: App {
  @State private var session = AppSession(role: .workbench)
  @State private var controller = FocusStatusItemController()
  var body: some Scene {
    WindowGroup("隔离专注内存诊断", id: "workbench") {
      WorkBenchRoot(session: session).frame(width: 980, height: 720)
        .background { FocusStatusItemObserver(controller: controller, session: session) }
        .task {
          await session.start()
          for _ in 0..<100 {
            if session.workspace != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
          if ProcessInfo.processInfo.environment["PROBE_FOCUS"] != "off" {
            if let store = session.workspace {
              _ = try? await store.perform(.startFocus(taskID: nil))
              print("FOCUS_READY", session.focusStatus != nil)
            } else {
              print("STARTUP_ERROR", session.error ?? "unknown")
            }
            fflush(nil)
          }
          if ProcessInfo.processInfo.environment["PROBE_CYCLES"] == "1",
            let store = session.workspace
          {
            for index in 0..<60 {
              try? await Task.sleep(for: .seconds(1))
              switch index % 4 {
              case 0: _ = try? await store.perform(.pauseFocus)
              case 1: _ = try? await store.perform(.startFocus(taskID: nil))
              case 2:
                if let focus = session.focusStatus {
                  _ = try? await store.perform(.endFocus(id: focus.id, resumeHint: nil))
                }
              default: _ = try? await store.perform(.startFocus(taskID: nil))
              }
              controller.update(session.focusStatus, session: session)
              print("FOCUS_PHASE", index)
              fflush(nil)
            }
          }

        }
    }
  }
}
