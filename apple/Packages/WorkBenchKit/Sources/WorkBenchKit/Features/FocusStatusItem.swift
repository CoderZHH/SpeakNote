#if os(macOS)
  import AppKit
  import Carbon.HIToolbox
  import Foundation
  import SwiftUI

  private final class GlassMenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
  }

  public struct GlobalHotKey: Codable, Equatable, Sendable, RawRepresentable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public var rawValue: String {
      "\(keyCode):\(carbonModifiers)"
    }

    public init?(rawValue: String) {
      let parts = rawValue.split(separator: ":")
      guard parts.count == 2,
        let code = UInt32(parts[0]),
        let mods = UInt32(parts[1])
      else { return nil }
      self.keyCode = code
      self.carbonModifiers = mods
    }

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
      self.keyCode = keyCode
      self.carbonModifiers = carbonModifiers
    }

    public static let `default` = GlobalHotKey(
      keyCode: UInt32(kVK_Space),
      carbonModifiers: UInt32(optionKey)
    )

    public static let presets: [(label: String, hotKey: GlobalHotKey)] = [
      ("⌥Space", .default),
      ("⌃Space", GlobalHotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey))),
      ("⌥⌘Space", GlobalHotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | cmdKey))),
      ("⇧⌥Space", GlobalHotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(shiftKey | optionKey))),
      ("⌃⌥K", GlobalHotKey(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey | optionKey))),
    ]

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
      var mods: UInt32 = 0
      if flags.contains(.control) { mods |= UInt32(controlKey) }
      if flags.contains(.option) { mods |= UInt32(optionKey) }
      if flags.contains(.shift) { mods |= UInt32(shiftKey) }
      if flags.contains(.command) { mods |= UInt32(cmdKey) }
      return mods
    }

    public var modifierDisplayString: String {
      var s = ""
      if (carbonModifiers & UInt32(controlKey)) != 0 { s += "⌃" }
      if (carbonModifiers & UInt32(optionKey)) != 0 { s += "⌥" }
      if (carbonModifiers & UInt32(shiftKey)) != 0 { s += "⇧" }
      if (carbonModifiers & UInt32(cmdKey)) != 0 { s += "⌘" }
      return s
    }

    public var keyDisplayString: String {
      switch Int(keyCode) {
      case kVK_Space: "Space"
      case kVK_Return: "↩"
      case kVK_Tab: "⇥"
      case kVK_Delete: "⌫"
      case kVK_Escape: "Esc"
      case kVK_ANSI_A: "A"
      case kVK_ANSI_B: "B"
      case kVK_ANSI_C: "C"
      case kVK_ANSI_D: "D"
      case kVK_ANSI_E: "E"
      case kVK_ANSI_F: "F"
      case kVK_ANSI_G: "G"
      case kVK_ANSI_H: "H"
      case kVK_ANSI_I: "I"
      case kVK_ANSI_J: "J"
      case kVK_ANSI_K: "K"
      case kVK_ANSI_L: "L"
      case kVK_ANSI_M: "M"
      case kVK_ANSI_N: "N"
      case kVK_ANSI_O: "O"
      case kVK_ANSI_P: "P"
      case kVK_ANSI_Q: "Q"
      case kVK_ANSI_R: "R"
      case kVK_ANSI_S: "S"
      case kVK_ANSI_T: "T"
      case kVK_ANSI_U: "U"
      case kVK_ANSI_V: "V"
      case kVK_ANSI_W: "W"
      case kVK_ANSI_X: "X"
      case kVK_ANSI_Y: "Y"
      case kVK_ANSI_Z: "Z"
      case kVK_ANSI_0: "0"
      case kVK_ANSI_1: "1"
      case kVK_ANSI_2: "2"
      case kVK_ANSI_3: "3"
      case kVK_ANSI_4: "4"
      case kVK_ANSI_5: "5"
      case kVK_ANSI_6: "6"
      case kVK_ANSI_7: "7"
      case kVK_ANSI_8: "8"
      case kVK_ANSI_9: "9"
      case kVK_ANSI_Equal: "="
      case kVK_ANSI_Minus: "-"
      case kVK_ANSI_RightBracket: "]"
      case kVK_ANSI_LeftBracket: "["
      case kVK_ANSI_Quote: "'"
      case kVK_ANSI_Semicolon: ";"
      case kVK_ANSI_Backslash: "\\"
      case kVK_ANSI_Comma: ","
      case kVK_ANSI_Slash: "/"
      case kVK_ANSI_Period: "."
      case kVK_ANSI_Grave: "`"
      case kVK_F1: "F1"
      case kVK_F2: "F2"
      case kVK_F3: "F3"
      case kVK_F4: "F4"
      case kVK_F5: "F5"
      case kVK_F6: "F6"
      case kVK_F7: "F7"
      case kVK_F8: "F8"
      case kVK_F9: "F9"
      case kVK_F10: "F10"
      case kVK_F11: "F11"
      case kVK_F12: "F12"
      case kVK_UpArrow: "↑"
      case kVK_DownArrow: "↓"
      case kVK_LeftArrow: "←"
      case kVK_RightArrow: "→"
      default: "按键 \(keyCode)"
      }
    }

    public var displayString: String {
      let mod = modifierDisplayString
      let key = keyDisplayString
      return mod.isEmpty ? key : "\(mod)\(key)"
    }
  }

  private final class HotKeyBox: @unchecked Sendable {
    var onTrigger: (@MainActor @Sendable () -> Void)?
  }

  private func menuBarHotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
  ) -> OSStatus {
    guard let userData else { return noErr }
    let box = Unmanaged<HotKeyBox>.fromOpaque(userData).takeUnretainedValue()
    let callback = box.onTrigger
    Task { @MainActor in callback?() }
    return noErr
  }

  /// A status item's title is native text, never a snapshot of a SwiftUI timer view.
  /// When `persistent` is enabled, left-clicking opens an on-demand Liquid Glass panel
  /// whose SwiftUI hierarchy is torn down immediately on close.
  @MainActor public final class FocusStatusItemController: NSObject, NSMenuDelegate {
    public let persistent: Bool
    private(set) var statusItem: NSStatusItem?
    private var timer: Timer?
    var openMainWindow: (() -> Void)?
    private var focus: FocusPresentation?
    private weak var session: AppSession?
    private var panel: GlassMenuBarPanel?
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private let hotKeyBox = HotKeyBox()
    private var hotKeyConfig: GlobalHotKey = .default
    public var currentHotKey: GlobalHotKey { hotKeyConfig }

    private let nameItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let timeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(
      title: "", action: #selector(toggleFocus), keyEquivalent: "")
    private let endItem = NSMenuItem(
      title: "结束专注", action: #selector(endFocus), keyEquivalent: "")
    private var contextMenu: NSMenu?

    public init(persistent: Bool = false) {
      self.persistent = persistent
      super.init()
      hotKeyBox.onTrigger = { [weak self] in
        MainActor.assumeIsolated { self?.togglePanel() }
      }
    }

    public var isPanelVisible: Bool {
      panel?.isVisible == true
    }

    public func setHotKey(enabled: Bool, hotKey: GlobalHotKey) {
      self.hotKeyConfig = hotKey
      configureAppearance()
      guard persistent, ProcessInfo.processInfo.environment["WORKBENCH_QA"] != "1" else {
        unregisterHotKey()
        return
      }
      if enabled {
        reregisterHotKey(hotKey)
      } else {
        unregisterHotKey()
      }
    }

    public func setHotKeyEnabled(_ enabled: Bool) {
      setHotKey(enabled: enabled, hotKey: hotKeyConfig)
    }

    private func reregisterHotKey(_ hotKey: GlobalHotKey) {
      unregisterHotKey()
      var eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      )
      let ptr = Unmanaged.passUnretained(hotKeyBox).toOpaque()
      InstallEventHandler(
        GetApplicationEventTarget(),
        menuBarHotKeyCallback,
        1,
        &eventType,
        ptr,
        &hotKeyHandlerRef
      )
      let hotKeyID = EventHotKeyID(signature: OSType(0x5350_4B4E), id: 1)  // 'SPKN'
      RegisterEventHotKey(
        hotKey.keyCode,
        hotKey.carbonModifiers,
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &hotKeyRef
      )
    }

    private func unregisterHotKey() {
      if let ref = hotKeyRef {
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
      }
      if let handler = hotKeyHandlerRef {
        RemoveEventHandler(handler)
        hotKeyHandlerRef = nil
      }
    }

    public func update(_ focus: FocusPresentation?, session: AppSession) {
      self.session = session
      self.focus = focus
      if !persistent && focus == nil {
        stop()
        return
      }
      ensureStatusItem()
      configureAppearance()
      tick()
      if let focus, focus.timer.isRunning {
        if timer == nil {
          let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
          }
          timer = tick
          RunLoop.main.add(tick, forMode: .common)
        }
      } else {
        timer?.invalidate()
        timer = nil
      }
    }

    private func ensureStatusItem() {
      guard statusItem == nil else { return }
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.button?.imagePosition = .imageLeading
      item.button?.font = .monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)

      let menu = buildMenu()
      contextMenu = menu

      if persistent {
        item.button?.target = self
        item.button?.action = #selector(handleStatusButtonClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
      } else {
        item.menu = menu
      }
      statusItem = item
    }

    private func buildMenu() -> NSMenu {
      let menu = NSMenu()
      menu.autoenablesItems = false
      menu.delegate = self
      nameItem.isEnabled = false
      timeItem.isEnabled = false
      toggleItem.target = self
      endItem.target = self
      if !persistent {
        menu.addItem(nameItem)
        menu.addItem(timeItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(endItem)
        menu.addItem(.separator())
      }
      let open = NSMenuItem(
        title: "打开随口记", action: #selector(openWindow), keyEquivalent: "")
      open.target = self
      menu.addItem(open)
      if persistent {
        let search = NSMenuItem(
          title: "全局搜索…", action: #selector(openSearch), keyEquivalent: "")
        search.target = self
        menu.addItem(search)
        menu.addItem(.separator())
        let quit = NSMenuItem(
          title: "退出随口记", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
      }
      return menu
    }

    private func configureAppearance() {
      guard let button = statusItem?.button else { return }
      let isPaused = focus != nil && focus?.timer.isRunning == false
      let desc =
        focus == nil
        ? "随口记快捷面板"
        : (isPaused ? "随口记 · 专注已暂停" : "随口记 · 专注计时")
      if button.image?.accessibilityDescription != desc {
        button.image = SpeakNoteBrandMark.menuBarImage(dimmed: isPaused, description: desc)
      }
    }

    private func tick() {
      guard let button = statusItem?.button else { return }
      if let focus {
        let title = focus.timer.elapsedText(at: .now)
        if button.title != title { button.title = title }
        button.toolTip = focus.timer.title + (focus.timer.isRunning ? " · 专注中" : " · 已暂停")
      } else {
        if !button.title.isEmpty { button.title = "" }
        button.toolTip = "随口记 · 点击打开快捷面板 (\(hotKeyConfig.displayString))"
      }
    }

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
      let event = NSApp.currentEvent
      let isRightClick =
        event?.type == .rightMouseUp
        || (event?.modifierFlags.contains(.control) == true)
      if isRightClick, let menu = contextMenu, let item = statusItem {
        closePanel()
        rebuildPersistentContextMenu(menu)
        item.menu = menu
        sender.performClick(nil)
        item.menu = nil
      } else {
        togglePanel()
      }
    }

    private func rebuildPersistentContextMenu(_ menu: NSMenu) {
      menu.removeAllItems()
      if let focus {
        nameItem.title = focus.timer.title
        timeItem.title = focus.timer.elapsedText(at: .now)
        toggleItem.title = focus.timer.isRunning ? "暂停专注" : "继续专注"
        menu.addItem(nameItem)
        menu.addItem(timeItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(endItem)
        menu.addItem(.separator())
      }
      let open = NSMenuItem(title: "打开随口记", action: #selector(openWindow), keyEquivalent: "")
      open.target = self
      menu.addItem(open)
      let search = NSMenuItem(title: "全局搜索…", action: #selector(openSearch), keyEquivalent: "")
      search.target = self
      menu.addItem(search)
      menu.addItem(.separator())
      let quit = NSMenuItem(title: "退出随口记", action: #selector(quitApp), keyEquivalent: "q")
      quit.target = self
      menu.addItem(quit)
    }

    public func togglePanel() {
      if isPanelVisible {
        closePanel()
      } else {
        showPanel()
      }
    }

    public func showPanel() {
      guard let session else { return }
      let targetPanel: GlassMenuBarPanel
      if let existing = panel {
        targetPanel = existing
      } else {
        let created = GlassMenuBarPanel(
          contentRect: NSRect(x: 0, y: 0, width: 332, height: 120),
          styleMask: [.borderless, .nonactivatingPanel],
          backing: .buffered,
          defer: true
        )
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.level = .popUpMenu
        created.animationBehavior = .utilityWindow
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        created.isMovableByWindowBackground = false
        created.hidesOnDeactivate = false
        panel = created
        targetPanel = created
      }

      let rootView = MenuBarQuickPanelView(
        session: session,
        openWorkspace: { [weak self] module in
          if module == .today { session.requestedAction = .openToday }
          self?.openWindow()
        },
        openGlobalSearch: { [weak self] in
          session.requestedAction = .openGlobalSearch
          self?.openWindow()
        },
        closePanel: { [weak self] in
          self?.closePanel()
        },
        onHeightChange: { [weak self, weak targetPanel] newHeight in
          guard let self, let targetPanel, targetPanel.isVisible else { return }
          let clamped = max(56, min(460, round(newHeight)))
          guard abs(targetPanel.frame.height - clamped) > 1 else { return }
          let size = NSSize(width: 332, height: clamped)
          let origin = self.anchorOrigin(for: size)
          targetPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
      )
      let hosting = NSHostingController(rootView: rootView)
      hosting.sizingOptions = [.intrinsicContentSize]
      targetPanel.contentViewController = hosting
      hosting.view.layoutSubtreeIfNeeded()
      let fitting = hosting.view.fittingSize
      let panelSize = NSSize(
        width: max(332, fitting.width),
        height: max(56, min(460, fitting.height))
      )

      let origin = anchorOrigin(for: panelSize)
      targetPanel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
      NSApp.activate(ignoringOtherApps: true)
      targetPanel.makeKeyAndOrderFront(nil)
      installDismissMonitors(for: targetPanel)
    }

    private func anchorOrigin(for size: NSSize) -> NSPoint {
      if let button = statusItem?.button, let buttonWindow = button.window {
        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(rectInWindow)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = screenRect.midX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        let y = screenRect.minY - size.height - 6
        return NSPoint(x: round(x), y: round(y))
      }
      let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
      return NSPoint(
        x: round(visible.midX - size.width / 2),
        y: round(visible.maxY - size.height - 12)
      )
    }

    private func installDismissMonitors(for targetPanel: NSPanel) {
      removeDismissMonitors()
      resignObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: targetPanel,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.closePanel() }
      }
      outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown]
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.closePanel() }
      }
    }

    private func removeDismissMonitors() {
      if let resignObserver {
        NotificationCenter.default.removeObserver(resignObserver)
        self.resignObserver = nil
      }
      if let outsideClickMonitor {
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
      }
    }

    public func closePanel() {
      removeDismissMonitors()
      guard let panel else { return }
      panel.orderOut(nil)
      // Tear down the SwiftUI hosting hierarchy immediately so closed state retains zero views.
      panel.contentViewController = nil
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

    @objc private func openSearch() {
      session?.requestedAction = .openGlobalSearch
      openWindow()
    }

    @objc private func quitApp() {
      NSApplication.shared.terminate(nil)
    }

    public func stop() {
      closePanel()
      panel = nil
      unregisterHotKey()
      timer?.invalidate()
      timer = nil
      if let item = statusItem {
        item.menu?.removeAllItems()
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
      }
      contextMenu?.removeAllItems()
      contextMenu = nil
      statusItem = nil
      focus = nil
    }
  }

  public struct GlobalHotKeyRecorder: View {
    @Binding public var hotKey: GlobalHotKey
    @State private var isRecording = false
    @State private var heldModifiers: UInt32 = 0
    @State private var errorTooltip: String?
    @State private var monitor: Any?

    public init(hotKey: Binding<GlobalHotKey>) {
      self._hotKey = hotKey
    }

    public var body: some View {
      HStack(spacing: 8) {
        Button {
          if isRecording {
            stopRecording()
          } else {
            startRecording()
          }
        } label: {
          HStack(spacing: 5) {
            if isRecording {
              Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
              Text(currentRecordingTitle)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
            } else {
              Image(systemName: "command")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Text(hotKey.displayString)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            isRecording
              ? Color.accentColor.opacity(0.12)
              : WorkbenchDesign.fieldBackground,
            in: RoundedRectangle(cornerRadius: 6)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(
                isRecording
                  ? Color.accentColor
                  : Color.primary.opacity(0.15),
                lineWidth: isRecording ? 1.5 : 1
              )
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "正在录制快捷键" : "快捷键 \(hotKey.displayString)")
        .help(isRecording ? "按下所需组合键，按 Esc 取消" : "点击以录制新的全局快捷键")

        if isRecording {
          Button {
            stopRecording()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("取消录制 (Esc)")
        } else if hotKey != .default {
          Button {
            hotKey = .default
          } label: {
            Image(systemName: "arrow.uturn.backward")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("恢复为默认快捷键 (⌥Space)")
        }

        if let errorTooltip {
          Text(errorTooltip)
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .onDisappear {
        stopRecording()
      }
    }

    private var currentRecordingTitle: String {
      if heldModifiers != 0 {
        var s = ""
        if (heldModifiers & UInt32(controlKey)) != 0 { s += "⌃" }
        if (heldModifiers & UInt32(optionKey)) != 0 { s += "⌥" }
        if (heldModifiers & UInt32(shiftKey)) != 0 { s += "⇧" }
        if (heldModifiers & UInt32(cmdKey)) != 0 { s += "⌘" }
        return "\(s) …"
      }
      return "按下快捷键…"
    }

    private func startRecording() {
      isRecording = true
      heldModifiers = 0
      errorTooltip = nil
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
        let type = event.type
        let code = event.keyCode
        let flags = event.modifierFlags
        var consume = false

        MainActor.assumeIsolated {
          guard isRecording else { return }
          if type == .flagsChanged {
            heldModifiers = GlobalHotKey.carbonModifiers(from: flags)
            consume = true
          } else if type == .keyDown {
            if code == UInt16(kVK_Escape) {
              stopRecording()
              consume = true
              return
            }
            if code == UInt16(kVK_Delete) {
              hotKey = .default
              stopRecording()
              consume = true
              return
            }
            let mods = GlobalHotKey.carbonModifiers(from: flags)
            let isFKey = (code >= UInt16(kVK_F1) && code <= UInt16(kVK_F12))
            let hasModifiers = (mods & UInt32(cmdKey | optionKey | controlKey)) != 0
            if hasModifiers || isFKey {
              hotKey = GlobalHotKey(keyCode: UInt32(code), carbonModifiers: mods)
              stopRecording()
              consume = true
            } else {
              errorTooltip = "需包含 ⌥、⌘ 或 ⌃"
              consume = true
            }
          }
        }
        return consume ? nil : event
      }
    }

    private func stopRecording() {
      isRecording = false
      heldModifiers = 0
      if let m = monitor {
        NSEvent.removeMonitor(m)
        monitor = nil
      }
    }
  }

  public struct FocusStatusItemObserver: View {
    let controller: FocusStatusItemController
    let session: AppSession
    @Environment(\.openWindow) private var openWindow
    @AppStorage("enableMenuBarHotKey") private var enableMenuBarHotKey = true
    @AppStorage("menuBarHotKey") private var menuBarHotKey: GlobalHotKey = .default

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
          controller.setHotKey(enabled: enableMenuBarHotKey, hotKey: menuBarHotKey)
        }
        .onChange(of: enableMenuBarHotKey) { _, enabled in
          controller.setHotKey(enabled: enabled, hotKey: menuBarHotKey)
        }
        .onChange(of: menuBarHotKey) { _, hotKey in
          controller.setHotKey(enabled: enableMenuBarHotKey, hotKey: hotKey)
        }
    }
  }
#else
  public struct GlobalHotKey: Codable, Equatable, Sendable, RawRepresentable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public var rawValue: String { "\(keyCode):\(carbonModifiers)" }

    public init?(rawValue: String) {
      let parts = rawValue.split(separator: ":")
      guard parts.count == 2, let code = UInt32(parts[0]), let mods = UInt32(parts[1]) else { return nil }
      self.keyCode = code
      self.carbonModifiers = mods
    }

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
      self.keyCode = keyCode
      self.carbonModifiers = carbonModifiers
    }

    public static let `default` = GlobalHotKey(keyCode: 49, carbonModifiers: 2048)
    public var displayString: String { "⌥Space" }
  }
#endif
