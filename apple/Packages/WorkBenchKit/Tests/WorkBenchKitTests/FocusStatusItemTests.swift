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

    @MainActor func testPersistentStatusItemStaysAvailableAndTearsDownPanelOnClose() throws {
      try XCTSkipUnless(
        ProcessInfo.processInfo.environment["WORKBENCH_UI_PROBE"] == "1", "独立菜单栏控件检查")
      NSApplication.shared.setActivationPolicy(.accessory)
      let controller = FocusStatusItemController(persistent: true)
      let session = AppSession(role: .workbench)
      defer { controller.stop() }

      controller.update(nil, session: session)
      let item = try XCTUnwrap(controller.statusItem)
      XCTAssertEqual(item.button?.title, "")

      let running = FocusPresentation(
        id: "focus-1", taskID: nil,
        timer: .init(title: "菜单栏专注", accumulatedSeconds: 125, activeSince: nil, isRunning: false))
      controller.update(running, session: session)
      XCTAssertTrue(controller.statusItem === item)
      XCTAssertEqual(item.button?.title, "00:02:05")

      controller.showPanel()
      XCTAssertTrue(controller.isPanelVisible)
      controller.closePanel()
      XCTAssertFalse(controller.isPanelVisible)

      controller.update(nil, session: session)
      XCTAssertTrue(controller.statusItem === item)
      XCTAssertEqual(item.button?.title, "")
    }

    @MainActor func testGlobalHotKeySerializationAndDisplayString() {
      let def = GlobalHotKey.default
      XCTAssertEqual(def.displayString, "⌥Space")
      XCTAssertEqual(def.rawValue, "49:2048")
      XCTAssertEqual(GlobalHotKey(rawValue: "49:2048"), def)
      XCTAssertNil(GlobalHotKey(rawValue: "invalid"))

      let ctrlSpace = GlobalHotKey(keyCode: 49, carbonModifiers: 4096)
      XCTAssertEqual(ctrlSpace.displayString, "⌃Space")

      let optCmdSpace = GlobalHotKey(keyCode: 49, carbonModifiers: 2048 | 256)
      XCTAssertEqual(optCmdSpace.displayString, "⌥⌘Space")

      let ctrlOptK = GlobalHotKey(keyCode: 40, carbonModifiers: 4096 | 2048)
      XCTAssertEqual(ctrlOptK.displayString, "⌃⌥K")

      for preset in GlobalHotKey.presets {
        XCTAssertFalse(preset.hotKey.displayString.isEmpty)
      }
    }

    @MainActor func testControllerUpdatesHotKeyAndAppearanceToolTip() {
      let controller = FocusStatusItemController(persistent: true)
      defer { controller.stop() }
      let custom = GlobalHotKey(keyCode: 40, carbonModifiers: 4096 | 2048)
      controller.setHotKey(enabled: false, hotKey: custom)
      XCTAssertEqual(controller.currentHotKey, custom)
    }
  }
#endif
