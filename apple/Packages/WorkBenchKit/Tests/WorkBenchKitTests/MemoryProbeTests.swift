#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  @testable import WorkBenchKit

  /// Opt-in, isolated native-window regression; never opens the installed application.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKBENCH_MEMORY_PROBE"] == "1"))
  @MainActor func nativeWindowMemoryProbe() async throws {
    try require(ProcessInfo.processInfo.environment["WORKBENCH_QA"] == "1", "内存检查必须禁用云端")
    print("MEMORY_PROBE_PID \(getpid())")
    fflush(nil)
    let f = try Fixture()
    defer { f.clean() }
    if let source = ProcessInfo.processInfo.environment["WORKBENCH_MEMORY_SOURCE"] {
      try SQLite(URL(fileURLWithPath: source), readOnly: true).backup(
        to: f.directory.appendingPathComponent("workbench.sqlite"))
      let photo = URL(fileURLWithPath: source).deletingLastPathComponent().appendingPathComponent(
        "photo.sqlite")
      if FileManager.default.fileExists(atPath: photo.path) {
        try SQLite(photo, readOnly: true).backup(
          to: f.directory.appendingPathComponent("photo.sqlite"))
      }
    } else {
      let engine = try f.workspace()
      for i in 0..<80 {
        _ = try engine.perform(
          .create(.tasks, fields: [.title: .string("待办 \(i)：长一点的内容，换行后也要保持稳定。\n第二行备注")]), now: .now)
      }
      for i in 0..<12 {
        _ = try engine.perform(
          .create(.notes, fields: [.content: .string("记录 \(i)\n多行长文本")]), now: .now)
      }
    }
    setenv("WORKBENCH_DB_PATH", f.directory.appendingPathComponent("workbench.sqlite").path, 1)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let session = AppSession(role: .workbench)
    await session.start()
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 1220, height: 820),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    if let raw = ProcessInfo.processInfo.environment["WORKBENCH_MEMORY_MODULE"],
      let module = AppModule(rawValue: raw)
    {
      window.contentViewController = NSHostingController(
        rootView: NavigationStack { ModuleContent(module: module) }.environment(session))
    } else {
      window.contentViewController = NSHostingController(rootView: WorkBenchRoot(session: session))
    }
    window.makeKeyAndOrderFront(nil)
    defer {
      window.close()
      window.contentViewController = nil
    }
    let modules: [AppModule?] =
      ProcessInfo.processInfo.environment["WORKBENCH_MEMORY_ALL"] == "1"
      ? AppModule.allCases.map { Optional($0) } : [nil]
    for module in modules {
      if let module {
        window.contentViewController = NSHostingController(
          rootView: NavigationStack { ModuleContent(module: module) }.environment(session))
      }
      for second in 0..<(modules.count > 1 ? 6 : 30) {
        try await Task.sleep(for: .seconds(1))
        if second % 2 == 1 {
          try await session.workspace?.refresh()
          try await session.photos?.refresh()
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("MEMORY_PROBE \(module?.rawValue ?? "root") \(second) peak_bytes=\(usage.ru_maxrss)")
        #expect(usage.ru_maxrss < 768 * 1024 * 1024)
      }
    }
  }

#endif
