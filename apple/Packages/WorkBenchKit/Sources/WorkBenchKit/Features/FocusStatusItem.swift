#if os(macOS)
  import SwiftUI
  import AppKit
  import Foundation

  /// A status item's title is native text, never a snapshot of a SwiftUI timer view.
  @MainActor public final class FocusStatusItemController: NSObject, NSMenuDelegate {
    private(set) var statusItem: NSStatusItem?
    private var timer: Timer?
    var openMainWindow: (() -> Void)?
    private var focus: FocusPresentation?
    private weak var session: AppSession?
    private let nameItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let timeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(
      title: "", action: #selector(toggleFocus), keyEquivalent: "")
    public override init() { super.init() }

    public func update(_ focus: FocusPresentation?, session: AppSession) {
      self.session = session
      self.focus = focus
      guard let focus else {
        stop()
        return
      }
      if statusItem == nil {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "专注计时")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(
          ofSize: NSFont.systemFontSize, weight: .regular)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        nameItem.isEnabled = false
        timeItem.isEnabled = false
        menu.addItem(nameItem)
        menu.addItem(timeItem)
        menu.addItem(.separator())
        toggleItem.target = self
        menu.addItem(toggleItem)
        let end = NSMenuItem(title: "结束专注", action: #selector(endFocus), keyEquivalent: "")
        end.target = self
        menu.addItem(end)
        menu.addItem(.separator())
        let open = NSMenuItem(
          title: "打开随口记", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        item.menu = menu
        statusItem = item
      }
      tick()
      if focus.timer.isRunning && timer == nil {
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.tick() }
        }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
      } else if !focus.timer.isRunning {
        timer?.invalidate()
        timer = nil
      }
    }
    private func tick() {
      guard let focus, let button = statusItem?.button else { return }
      let title = focus.timer.elapsedText(at: .now)
      if button.title != title { button.title = title }
      button.toolTip = focus.timer.title + (focus.timer.isRunning ? " · 专注中" : " · 已暂停")
    }
    public func menuWillOpen(_ menu: NSMenu) {
      guard let focus else { return }
      nameItem.title = focus.timer.title
      timeItem.title = focus.timer.elapsedText(at: .now)
      toggleItem.title = focus.timer.isRunning ? "暂停" : "继续"
    }
    @objc private func toggleFocus() {
      guard let focus, let session else { return }
      session.run { [weak self] in
        _ = try await session.workspace?.perform(
          focus.timer.isRunning ? .pauseFocus : .startFocus(taskID: focus.taskID))
        self?.update(session.focusStatus, session: session)
      }
    }
    @objc private func endFocus() {
      guard let focus, let session else { return }
      session.run { [weak self] in
        _ = try await session.workspace?.perform(.endFocus(id: focus.id, resumeHint: nil))
        self?.update(session.focusStatus, session: session)
      }
    }
    @objc private func openWindow() {
      openMainWindow?()
      NSApplication.shared.activate()
    }
    public func stop() {
      timer?.invalidate()
      timer = nil
      if let item = statusItem {
        item.menu?.removeAllItems()
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
      }
      statusItem = nil
      focus = nil
    }
  }
  public struct FocusStatusItemObserver: View {
    let controller: FocusStatusItemController
    let session: AppSession
    @Environment(\.openWindow) private var openWindow
    public init(controller: FocusStatusItemController, session: AppSession) {
      self.controller = controller
      self.session = session
    }
    public var body: some View {
      Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
        .onChange(of: session.focusStatus, initial: true) { _, focus in
          let open = openWindow
          controller.openMainWindow = { open(id: "workbench") }
          controller.update(focus, session: session)
        }
    }
  }
#endif
