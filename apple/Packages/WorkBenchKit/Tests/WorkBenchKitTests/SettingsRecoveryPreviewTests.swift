#if os(macOS)
import AppKit
import CloudKit
import SwiftUI
import Testing

@testable import WorkBenchKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["WORKBENCH_SETTINGS_PREVIEW"] == "1"))
@MainActor func settingsRecoveryNativePreview() async throws {
  try require(ProcessInfo.processInfo.environment["WORKBENCH_QA"] == "1", "Preview requires cloud disabled")
  let fixture = try Fixture()
  defer { fixture.clean() }
  let engine = try fixture.workspace()
  let note = try engine.perform(.create(.notes, fields: [.content: .string("附件加不上：保留的一份修改")]), now: testNow).id!
  var saved = try engine.db.record("notes", id: note)
  saved["content"] = .string("附件加不上：另一端保留的修改。这里是一段较长的内容，用于检查窄窗口中比较双方版本时能完整换行，保留当前或使用保留版本都可以直接完成处理。")
  try engine.db.insert("wb_sync_conflicts", [
    "id": .id(), "entity": .string("notes"), "record_id": .string(note),
    "payload": .string(try JSONValue.object(saved).json()),
    "created_at": .string(Clock.stamp(testNow)),
  ])
  let photos = try fixture.photos()
  try photos.bind(fixture.space)
  var input = PhotoOrderInput()
  input.brand = "示例订单：双方修改待核对"
  _ = try photos.perform(.create(input), now: testNow)
  let seed = try photos.pendingDocuments()
  for doc in seed { try photos.acknowledge(doc, serverFields: "seed") }
  _ = try photos.perform(.patch(id: input.id, field: .brand,
    before: .string(input.brand), value: .string("本机订单名称")), now: testNow)
  var remote = try #require(seed.first { $0.kind == "order" })
  remote.payload["brand"] = .string("共享订单名称")
  try photos.receive([remote])
  let oldPath = ProcessInfo.processInfo.environment["WORKBENCH_DB_PATH"]
  setenv("WORKBENCH_DB_PATH", fixture.directory.appendingPathComponent("workbench.sqlite").path, 1)
  defer {
    if let oldPath { setenv("WORKBENCH_DB_PATH", oldPath, 1) }
    else { unsetenv("WORKBENCH_DB_PATH") }
  }
  let session = AppSession(role: .workbench)
  await session.start()
  try require(session.workspace != nil, session.error ?? "Preview failed")
  session.syncMessage = describeCloudError(NSError(domain: CKErrorDomain,
    code: CKError.networkFailure.rawValue, userInfo: [
      NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed),
    ]))
  NSApplication.shared.setActivationPolicy(.accessory)
  let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 1000),
    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close(); window.contentViewController = nil }
  for (name, width, previewSession) in [
    ("wide", 900.0, session), ("narrow", 430.0, session),
    ("comparison", 900.0, session), ("comparison-narrow", 340.0, session),
    ("comparison-dark", 430.0, session),
    ("empty", 430.0, AppSession(role: .photoAssistant)),
  ] {
    window.setContentSize(NSSize(width: width, height: 1000))
    window.appearance = NSAppearance(named: name.hasSuffix("dark") ? .darkAqua : .aqua)
    let host = NSHostingController(rootView: NavigationStack {
      if name.hasPrefix("comparison"), let conflict = session.workspace?.snapshot.conflicts.first {
        Form { WorkspaceConflictReview(conflict: conflict, initiallyExpanded: true) }.workspaceSettingsForm()
      } else { SettingsView() }
    }.environment(previewSession).frame(width: width, height: 1000))
    window.contentViewController = host
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(400))
    host.view.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(
      to: URL(fileURLWithPath: "/tmp/workbench-settings-" + name + ".png"))
  }
}
#endif
