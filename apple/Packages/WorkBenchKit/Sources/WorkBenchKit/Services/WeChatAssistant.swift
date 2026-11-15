#if os(macOS)
import CryptoKit
import Foundation
import Observation
import Security

private struct AssistantKeychain {
  let account: String

  init(directory: URL) {
    let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
    account = digest.map { String(format: "%02x", $0) }.joined()
  }

  private func query(_ name: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "io.github.coderzhh.workbenchpreview." + name,
      kSecAttrAccount as String: account,
    ]
  }

  func load<T: Decodable>(_ name: String) throws -> T? {
    var request = query(name)
    request[kSecReturnData as String] = true
    var value: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let data = value as? Data else { throw WorkBenchError("无法读取钥匙串中的微信助手配置") }
    return try JSONDecoder().decode(T.self, from: data)
  }

  func store<T: Encodable>(_ value: T, as name: String) throws {
    let data = try JSONEncoder().encode(value)
    let request = query(name)
    let status = SecItemUpdate(request as CFDictionary, [kSecValueData: data] as CFDictionary)
    if status == errSecItemNotFound {
      var attributes = request
      attributes[kSecValueData as String] = data
      try check(SecItemAdd(attributes as CFDictionary, nil))
    } else {
      try check(status)
    }
  }

  func remove(_ name: String) throws {
    let status = SecItemDelete(query(name) as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      throw WorkBenchError("无法访问 macOS 钥匙串（\(status)），请检查钥匙串是否已解锁。")
    }
  }
}

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
  @ObservationIgnored private var keychain: AssistantKeychain?
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
    let keychain = AssistantKeychain(directory: directory)
    self.files = files
    self.keychain = keychain
    sendToWorkspace = { [weak session, weak store] operation, args in
      guard let session, let store else { return .object(["error": .string("工作区尚未就绪")]) }
      return await session.handleAssistant(operation, args, store: store)
    }
    do {
      let binding: WeChatCredentials? = try keychain.load("wechat")
      let key: String? = try keychain.load("deepseek")
      connected = binding != nil
      hasKey = key != nil
      // The assistant folder is created only after a user opts in.
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
    guard let files, let keychain, !busy, !connected, !stopping else { return }
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
          try keychain.store(credentials, as: "wechat")
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
    guard let keychain, !verifying else { return }
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
        try keychain.store(key, as: "deepseek")
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
    guard let keychain, !verifying, !stopping else { return }
    await stop()
    do {
      try keychain.remove("deepseek")
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
    guard let files, let keychain, !busy, !stopping, !verifying else { return }
    await stop()
    do {
      try await files.exclusively {
        try keychain.remove("wechat")
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
    guard let files, let keychain, let sendToWorkspace, connected, hasKey,
      poller == nil, !stopping, !paused else { return }
    do {
      guard let credentials: WeChatCredentials = try keychain.load("wechat"),
        let key: String = try keychain.load("deepseek")
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
