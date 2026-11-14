#if os(macOS)
  import AppKit
  import SwiftUI
  import XCTest
  @testable import WorkBenchKit

  final class ItemActionPresentationTests: XCTestCase {
    @MainActor func testMacThoughtEditorShowsTitleAndBody() async throws {
      try XCTSkipUnless(
        ProcessInfo.processInfo.environment["WORKBENCH_UI_PROBE"] == "1", "独立 Mac 编辑器渲染检查")
      NSApplication.shared.setActivationPolicy(.accessory)
      let content = "把第一行作为标题\n这里是正文，字号与标题有清晰的层次。\n保留连续编辑、换行和自动保存。"
      let view = NSHostingView(
        rootView: ThoughtTextEditor(text: .constant(content), focused: .constant(false)).background(
          .white
        ).environment(\.colorScheme, .light))
      let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 620, height: 350), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = view
      window.makeKeyAndOrderFront(nil)
      defer {
        window.close()
        window.contentView = nil
      }
      try await Task.sleep(for: .seconds(1))
      window.displayIfNeeded()
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: "/tmp/workbench-mac-thought-title.png"))
    }
    @MainActor func testMacPalettePaintsAllFiveColors() async throws {
      try XCTSkipUnless(
        ProcessInfo.processInfo.environment["WORKBENCH_UI_PROBE"] == "1", "独立 Mac 渲染验证，默认不创建窗口")
      NSApplication.shared.setActivationPolicy(.accessory)
      let item = WorkspaceItem(
        entity: .tasks,
        fields: [
          "id": .string("palette-test"), "title": .string("检查重要程度"), "status": .string("todo"),
          "importance": .integer(3),
        ])
      // Native popovers provide this backing surface; the offscreen snapshot needs one too.
      let view = NSHostingView(
        rootView: ItemActionPanel(item: item) { _ in }.background(.white).environment(
          \.colorScheme, .light))
      let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 280, height: 345), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = view
      window.makeKeyAndOrderFront(nil)
      defer {
        window.close()
        window.contentView = nil
      }
      try await Task.sleep(for: .seconds(1))
      window.displayIfNeeded()
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "/tmp/workbench-mac-priority-panel.png"))
      var pixels: [(x: Int, y: Int, color: Int)] = []
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
          guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
          let r = c.redComponent
          let g = c.greenComponent
          let b = c.blueComponent
          let color: Int?
          if b > 0.7 && b - r > 0.3 && b - g > 0.2 {
            color = 3
          } else if g - r > 0.25 && b - r > 0.25 && abs(g - b) < 0.25 {
            color = 2
          } else if r > 0.7 && r - g > 0.15 && g - b > 0.2 {
            color = 4
          } else if r > 0.7 && r - g > 0.4 && r - b > 0.3 {
            color = 5
          } else if abs(r - g) < 0.08 && abs(g - b) < 0.08 && r > 0.3 && r < 0.8 {
            color = 1
          } else {
            color = nil
          }
          if let color { pixels.append((x, y, color)) }
        }
      }
      let blue = pixels.filter { $0.color == 3 }
      XCTAssertFalse(blue.isEmpty, "原生 Mac 面板必须实际绘制色点，不能只剩空白占位")
      guard !blue.isEmpty else { return }
      let centerY = blue.map(\.y).reduce(0, +) / blue.count
      for level in 1...5 {
        XCTAssertGreaterThan(
          pixels.filter { $0.color == level && abs($0.y - centerY) < 20 }.count, 40,
          "第 \(level) 个颜色在选择行里不可见")
      }
    }
  }
#endif
