#if os(macOS)
import Foundation
import Observation

@MainActor @Observable final class WeChatAssistant {
  private(set) var connected = false
  private(set) var hasKey = false
  private(set) var running = false
  private(set) var online = false
  private(set) var busy = false
  private(set) var verifying = false
  private(set) var qr: Data?
  private(set) var scanned = false
  private(set) var needsPIN = false
  private(set) var issue: String?
  private(set) var trialIssue: String?
  private(set) var taskID: String?
  private(set) var ready = false
  private(set) var paused = false
  private(set) var stopping = false

  @ObservationIgnored private var files: AssistantFiles?
  @ObservationIgnored private var binding: Task<Void, Never>?
  @ObservationIgnored private var validation: Task<Void, Never>?
  @ObservationIgnored private var poller: Task<Void, Never>?
  @ObservationIgnored private var pin: CheckedContinuation<String, any Error>?
  @ObservationIgnored private var sendToWorkspace: (@Sendable (String, JSONValue) async -> JSONValue)?

  func configure(session: AppSession, store: WorkspaceStore, directory: URL) {
    guard !ready else { return }
    issue = nil
    let local = AssistantLocal(workspaceDirectory: directory)
    let files = AssistantFiles(local: local)
    self.files = files
    sendToWorkspace = { [weak session, weak store] operation, args in
      guard let session, let store else { return .object(["error": .string("工作区尚未就绪")]) }
      return await session.handleAssistant(operation, args, store: store)
    }
    do {
      // Stored inside the app's own 0700/0600 workspace directory (like ~/.ssh):
      // never triggers macOS login-keychain password prompts across rebuilds/updates,
      // and leaves zero orphaned items in macOS Keychain on uninstall.
      let binding: WeChatCredentials? = try files.load("wechat.json")
      let key: String? = try files.load("deepseek.json")
      connected = binding != nil
      hasKey = key != nil
      if connected {
        try local.prepare()
        paused = try files.load("paused.json") ?? false
        let state: AssistantState? = try files.load("state.json")
        if let id = state?.firstTaskID, store.snapshot.item(.tasks, id) != nil { taskID = id }
      }
      ready = true
      if !paused { start() }
    } catch {
      issue = AssistantCommand.display(error)
    }
  }

  func connect() {
    guard let files, !busy, !connected, !stopping else { return }
    issue = nil
    qr = nil
    scanned = false
    needsPIN = false
    busy = true
    binding = Task { [weak self] in
      guard let self else { return }
      defer {
        self.binding = nil
        self.busy = false
        self.qr = nil
        self.needsPIN = false
      }
      do {
        try files.local.prepare()
        let client = WeChatClient()
        let code = try await client.makeQR()
        try Task.checkCancellation()
        self.qr = try WeChatClient.pngQR(code.payload)
        let credentials = try await client.waitForPair(id: code.id, onScan: {
          self.scanned = true
        }, askPIN: {
          self.scanned = true
          self.needsPIN = true
          return try await withCheckedThrowingContinuation { self.pin = $0 }
        })
        try Task.checkCancellation()
        try await files.exclusively {
          try files.resetConversation()
          try files.save(credentials, to: "wechat.json", excludeFromBackup: true)
        }
        self.paused = false
        self.connected = true
      } catch {
        if !Task.isCancelled { self.issue = AssistantCommand.display(error) }
      }
    }
  }

  func submitPIN(_ value: String) {
    guard let pin, (4...10).contains(value.count), value.utf8.allSatisfy({ (48...57).contains($0) })
    else { return }
    self.pin = nil
    needsPIN = false
    pin.resume(returning: value)
  }

  func closeSetup() {
    binding?.cancel()
    validation?.cancel()
    pin?.resume(throwing: CancellationError())
    pin = nil
  }

  func saveKey(_ input: String) {
    guard let files, !verifying else { return }
    let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
    issue = nil
    guard key.hasPrefix("sk-"), (13...199).contains(key.count),
      key.utf8.allSatisfy({ (33...126).contains($0) })
    else { issue = "请输入有效的 DeepSeek API Key。"; return }
    verifying = true
    validation = Task { [weak self] in
      guard let self else { return }
      defer { self.verifying = false; self.validation = nil }
      do {
        try await DeepSeekClient(key: key).validate()
        try Task.checkCancellation()
        await self.stop()
        try Task.checkCancellation()
        try files.save(key, to: "deepseek.json", excludeFromBackup: true)
        self.hasKey = true
        if !self.paused { self.start() }
      } catch {
        let failure = Task.isCancelled ? nil : AssistantCommand.display(error)
        if !self.paused { self.start() }
        if let failure { self.issue = failure }
      }
    }
  }

  func clearKey() async {
    guard let files, !verifying, !stopping else { return }
    await stop()
    do {
      try files.remove("deepseek.json")
      hasKey = false
      taskID = nil
      issue = nil
    } catch {
      issue = AssistantCommand.display(error)
    }
  }

  func setPaused(_ paused: Bool) async {
    guard let files, !stopping, !verifying else { return }
    do {
      try files.save(paused, to: "paused.json")
      self.paused = paused
      issue = nil
      if paused { await stop() } else { start() }
    } catch {
      issue = AssistantCommand.display(error)
    }
  }

  func disconnect() async {
    guard let files, !busy, !stopping, !verifying else { return }
    await stop()
    do {
      try await files.exclusively {
        try files.remove("wechat.json")
        connected = false
        try files.resetConversation()
      }
      paused = false
      taskID = nil
      trialIssue = nil
      issue = nil
    } catch {
      issue = AssistantCommand.display(error)
    }
  }

  func start() {
    guard let files, let sendToWorkspace, connected, hasKey,
      poller == nil, !stopping, !paused else { return }
    do {
      guard let credentials: WeChatCredentials = try files.load("wechat.json"),
        let key: String = try files.load("deepseek.json")
      else { throw WorkBenchError("请重新配置微信和 DeepSeek。") }
      issue = nil
      online = false
      running = true
      let agent = Agent(workspace: sendToWorkspace, completion: {
        try await DeepSeekClient(key: key).complete($0)
      })
      poller = Task { [weak self] in
        do {
          try await files.exclusively {
            try await AssistantCommand.serve(credentials, agent: agent, files: files, status: { [weak self] message in
              await self?.updateConnection(message)
            }, onReply: { [weak self] reply in
              await self?.updateTrial(reply)
            })
          }
        } catch {
          if !Task.isCancelled { self?.issue = AssistantCommand.display(error) }
        }
        self?.poller = nil
        self?.online = false
        self?.running = false
      }
    } catch {
      issue = AssistantCommand.display(error)
    }
  }

  private func stop() async {
    guard let poller else { return }
    stopping = true
    poller.cancel()
    await poller.value
    stopping = false
  }

  private func updateConnection(_ message: String?) {
    online = message == nil
    issue = message
  }

  private func updateTrial(_ reply: AgentReply) {
    if let id = reply.createdTaskID {
      taskID = id
      trialIssue = nil
    } else if reply.failed {
      trialIssue = reply.text
    }
  }
}
#endif
