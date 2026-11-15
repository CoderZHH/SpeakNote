#if os(macOS)
import Darwin
import Foundation
import Network
import Security

/// One JSON line per local connection. The directory and credentials belong to the current user.
public struct AssistantLocal: Sendable {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }
  public init(workspaceDirectory: URL) {
    directory = workspaceDirectory.appendingPathComponent("assistant", isDirectory: true)
  }
  public static func current() throws -> Self {
    Self(workspaceDirectory: try DataLocation.current(role: .workbench).directory)
  }
  var socketPath: String { directory.appendingPathComponent("bridge.sock").path }
  private var keyURL: URL { directory.appendingPathComponent("bridge.key") }

  public func prepare() throws {
    if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
      throw WorkBenchError("无法创建本机助手目录")
    }
    try checkDirectory()
    if try key() != nil { return }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw WorkBenchError("无法生成本机连接凭据")
    }
    try Data(Data(bytes).base64EncodedString().utf8).write(to: keyURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
  }

  private func checkDirectory() throws {
    var info = stat()
    try require(lstat(directory.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
      && info.st_uid == geteuid() && info.st_mode & 0o077 == 0, "助手目录需要由当前用户独占（权限 700）")
  }

  func key() throws -> String? {
    var info = stat()
    if lstat(keyURL.path, &info) != 0 {
      if errno == ENOENT { return nil }
      throw WorkBenchError("无法读取本机连接凭据")
    }
    try checkDirectory()
    try require(info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid()
      && info.st_mode & 0o077 == 0 && info.st_size == 44, "本机连接凭据格式或权限不正确")
    return try String(contentsOf: keyURL, encoding: .utf8)
  }

  public func request(_ operation: String, _ arguments: JSONValue = .null) async throws -> JSONValue {
    guard let key = try key() else { throw WorkBenchError("尚未启用 WorkBench 助手连接") }
    let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    connection.start(queue: assistantNetwork)
    return try await withAssistantConnection(connection) {
      try await connection.writeAssistant(.object([
        "key": .string(key), "operation": .string(operation), "arguments": arguments,
      ]))
      return try await connection.readAssistant()
    }
  }
}

private let assistantNetwork = DispatchQueue(label: "WorkBench.AssistantBridge")
// One 8 MiB image plus Base64 overhead and metadata.
private let assistantPacketLimit = 12 * 1024 * 1024

private func withAssistantConnection<T: Sendable>(
  _ connection: NWConnection, body: () async throws -> T
) async throws -> T {
  let deadline = DispatchWorkItem { connection.cancel() }
  assistantNetwork.asyncAfter(deadline: .now() + 8, execute: deadline)
  defer { deadline.cancel(); connection.cancel() }
  return try await withTaskCancellationHandler {
    try await body()
  } onCancel: { connection.cancel() }
}

private extension NWConnection {
  func readAssistant() async throws -> JSONValue {
    var packet = Data()
    while packet.count < assistantPacketLimit {
      let (data, end): (Data, Bool) = try await withCheckedThrowingContinuation { continuation in
        receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, end, error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume(returning: (data ?? Data(), end)) }
        }
      }
      if let lineEnd = data.firstIndex(of: 10), packet.count + data.distance(from: data.startIndex, to: lineEnd) < assistantPacketLimit {
        packet.append(contentsOf: data[..<lineEnd])
        return try JSONValue(data: packet)
      }
      packet.append(data)
      if end || data.isEmpty { break }
    }
    throw WorkBenchError("本机助手消息不完整或过长")
  }

  func writeAssistant(_ payload: JSONValue) async throws {
    var data = try payload.data()
    try require(data.count < assistantPacketLimit, "本机助手消息过长")
    data.append(10)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }
}

final class AssistantBridge {
  let listener: NWListener
  private let lock: Int32

  init?(_ local: AssistantLocal, handle: @escaping @Sendable (String, JSONValue) async -> JSONValue)
    throws
  {
    guard let key = try local.key() else { return nil }
    let path = local.socketPath
    try require(path.utf8.count < 104, "助手目录路径过长")
    let fd = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw WorkBenchError("无法锁定本机助手连接") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(fd)
      throw WorkBenchError("已有 WorkBench 助手连接在运行")
    }
    do {
      // Only the lock owner may replace a socket left behind after a crash.
      if unlink(path) != 0 && errno != ENOENT { throw WorkBenchError("无法清理旧的助手连接") }
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .unix(path: path)
      listener = try NWListener(using: parameters)
    } catch {
      Darwin.close(fd)
      throw error
    }
    lock = fd
    listener.newConnectionHandler = { connection in
      connection.start(queue: assistantNetwork)
      Task {
        _ = try? await withAssistantConnection(connection) {
          let request = try await connection.readAssistant()
          guard request["key"] == .string(key) else {
            try await connection.writeAssistant(.object(["error": .string("助手连接未授权")]))
            return
          }
          try await connection.writeAssistant(await handle(request["operation"].string, request["arguments"]))
        }
      }
    }
    listener.start(queue: assistantNetwork)
  }

  deinit {
    listener.cancel()
    Darwin.close(lock)
  }
}

extension AppSession {
  func startAssistantBridge(_ store: WorkspaceStore) {
    do {
      let local = AssistantLocal(workspaceDirectory: store.database.url.deletingLastPathComponent())
      assistantBridge = try AssistantBridge(local) { [weak self, weak store] operation, arguments in
        guard let self, let store else {
          return .object(["error": .string("WorkBench 尚未打开")])
        }
        return await self.handleAssistant(operation, arguments, store: store)
      }
    } catch { self.error = error.localizedDescription }
  }

  func handleAssistant(_ operation: String, _ arguments: JSONValue, store: WorkspaceStore)
    async -> JSONValue
  {
    let db = store.database
    do {
      let result: JSONValue
      switch operation {
      case "ping": result = .string("ready")
      case "search": result = try await db.assistantSearch(arguments)
      case "recent": result = try await db.assistantRecentContext()
      case "schedule": result = try await db.assistantCourseSchedule(arguments)
      case "receipt":
        result = try await db.assistantReceipt(assistantRequestID(arguments.string)) ?? .null
      case "apply":
        let id = try assistantRequestID(arguments["request_id"].string)
        if let receipt = try await db.assistantReceipt(id) {
          result = receipt
          break
        }
        let changes = arguments["changes"]
        if changes.array.contains(where: {
          $0["fields"]["reminder_enabled"] == .bool(true) || !$0["fields"]["reminder_at"].isNull
            || $0["kind"] == .string("remind_course")
        }) { try await reminders.checkAuthorization() }
        let staging = EntryAttachmentStaging()
        var attachments: [StagedEntryAttachment] = []
        if changes.array.contains(where: { $0["attach_image"] == .bool(true) }) {
          let encoded = arguments["image"].string
          guard let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 8 * 1024 * 1024 else {
            throw WorkBenchError("请把要保存的图片随文字一起发送（最多 8 MB）")
          }
          attachments = [try await staging.add(data: bytes, name: "微信图片")]
        }
        result = try await db.applyAssistantChanges(changes, requestID: id, attachments: attachments)
        await staging.discard()
        scheduleSync()
        try? await store.refresh()
      case "prepare_timetable":
        result = try await db.prepareAssistantTimetable(arguments["timetable"],
          requestID: assistantRequestID(arguments["request_id"].string))
      case "prepare":
        let plan = try await db.prepareAssistantPlan(arguments, source: "wechat")
        result = try plan.preview()
      case "commit":
        result = try await db.commitAssistantPlan(id: arguments.string)
        scheduleSync()
        try? await store.refresh()
      case "cancel":
        try await db.cancelAssistantPlan(id: arguments.string)
        result = .null
      default: throw WorkBenchError("助手不支持这项操作")
      }
      return .object(["result": result])
    } catch let error as WorkBenchError { return .object(["error": .string(error.message)]) }
    catch { return .object(["error": .string("WorkBench 操作失败，请检查工作区状态")]) }
  }

  private func assistantRequestID(_ id: String) throws -> String {
    try require(id.range(of: "^wechat-[0-9a-f]{64}$", options: .regularExpression) != nil, "消息编号无效")
    return id
  }
}
#endif
