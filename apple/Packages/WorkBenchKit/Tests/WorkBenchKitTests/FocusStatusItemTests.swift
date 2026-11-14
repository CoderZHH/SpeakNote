#if os(macOS)
  import AppKit
  import XCTest
  @testable import WorkBenchKit

  final class FocusStatusItemTests: XCTestCase {
    @MainActor func testNativeStatusItemReusesOneItemAndRestartsCleanly() throws {
      try XCTSkipUnless(
        ProcessInfo.processInfo.environment["WORKBENCH_UI_PROBE"] == "1", "独立菜单栏控件检查")
      NSApplication.shared.setActivationPolicy(.accessory)
      let controller = FocusStatusItemController()
      let session = AppSession(role: .workbench)
      let running = FocusPresentation(
        id: "test", taskID: nil,
        timer: .init(title: "诊断专注", accumulatedSeconds: 30, activeSince: .now, isRunning: true))
      let paused = FocusPresentation(
        id: "test", taskID: nil,
        timer: .init(title: "诊断专注", accumulatedSeconds: 67, activeSince: nil, isRunning: false))
      defer { controller.stop() }
      for _ in 0..<30 {
        controller.update(running, session: session)
        let item = try XCTUnwrap(controller.statusItem)
        for _ in 0..<100 { controller.update(running, session: session) }
        XCTAssertTrue(controller.statusItem === item)
        controller.update(paused, session: session)
        XCTAssertEqual(item.button?.title, "00:01:07")
        let menu = try XCTUnwrap(item.menu)
        controller.menuWillOpen(menu)
        XCTAssertEqual(menu.item(at: 0)?.title, "诊断专注")
        XCTAssertEqual(menu.item(at: 3)?.title, "继续")
        controller.update(nil, session: session)
        XCTAssertNil(controller.statusItem)
        XCTAssertNil(item.menu)
      }
    }
  }
#endif
