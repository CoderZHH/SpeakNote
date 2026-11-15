#if os(macOS)
import AppKit
import CryptoKit
import Darwin
import Foundation

struct AssistantState: Codable {
  var cursor = ""
  var firstTaskID: String?
  var history: [ChatTurn] = []
  var pending: PendingChange?
  var handled: [String] = []
  var outbox: Outbox?
  var recentImageAt: Date?
  var recentUserAt: Date?
  var recentUserInstruction: String?
  var inbox: ConversationBatch?
  var inFlight: ConversationBatch?
  var waitingForImage: Bool?
  func instructionForIncomingImage(now: Date = .now) -> String? {
    guard waitingForImage == true, let date = recentUserAt, now.timeIntervalSince(date) < 120,
      let instruction = recentUserInstruction else { return nil }
    return "用户紧接上一条消息发来了图片。上一条文字请求是「\(instruction)」。请结合聊天上下文处理这张图。"
  }

  struct Outbox: Codable {
    let id: String
    let context: String
    let runID: String?
    let text: String
  }
}

struct AssistantFiles {
  let local: AssistantLocal

  func load<T: Decodable>(_ file: String) throws -> T? {
    let url = local.directory.appendingPathComponent(file)
    var info = stat()
    if lstat(url.path, &info) != 0 {
      if errno == ENOENT { return nil }
      throw WorkBenchError("无法读取助手配置")
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
      info.st_mode & 0o077 == 0, info.st_size <= 2_000_000
    else { throw WorkBenchError("助手配置权限或大小不正确") }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
  }

  func save<T: Encodable>(_ value: T, to file: String) throws {
    let url = local.directory.appendingPathComponent(file)
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func resetConversation() throws {
    for name in ["state.json", "recent-image.data", "paused.json"] {
      do { try FileManager.default.removeItem(at: local.directory.appendingPathComponent(name)) }
      catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
    }
  }

  func cacheImage(_ dataURL: String) throws {
    let url = local.directory.appendingPathComponent("recent-image.data")
    try Data(dataURL.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func cachedImage(since date: Date?) throws -> String? {
    let url = local.directory.appendingPathComponent("recent-image.data")
    guard let date, Date.now.timeIntervalSince(date) < 600 else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    let info = try FileManager.default.attributesOfItem(atPath: url.path)
    guard (info[.size] as? Int ?? 0) <= 12 * 1024 * 1024 else {
      throw WorkBenchError("暂存图片太大，请重新发送")
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  func exclusively<T>(isolation: isolated (any Actor)? = #isolation, _ operation: () async throws -> T) async throws -> T {
    let fd = Darwin.open(local.directory.appendingPathComponent("service.lock").path,
      O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw WorkBenchError("请先运行 setup") }
    defer { Darwin.close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WorkBenchError("助手正在运行，请先停止") }
    return try await operation()
  }
}

public enum AssistantCommand {
  public static func main() async {
    umask(0o077)
    do { try await execute(CommandLine.arguments.dropFirst().first ?? "help") }
    catch {
      FileHandle.standardError.write(Data((display(error) + "\n").utf8))
      exit(1)
    }
  }

  private static func execute(_ action: String) async throws {
    if ["help", "--help", "-h"].contains(action) {
      print("""
        设置 WORKBENCH_WORKSPACE_ROOT 为项目目录，再执行：
        workbench-assistant setup   准备 WorkBench 本机连接
        workbench-assistant status  检查 WorkBench 是否在线
        workbench-assistant pair    扫码绑定自己的微信
        workbench-assistant key     在本机输入 DeepSeek API Key
        workbench-assistant run     在终端运行助手（Control-C 停止）
        配置与会话保存在工作区的 data/assistant/。
        """)
      return
    }
    let local = try AssistantLocal.current()
    let files = AssistantFiles(local: local)
    switch action {
    case "setup":
      try local.prepare()
      print("已准备本机连接。请重新打开 WorkBench，再运行 status。")
    case "status":
      let result = try await local.request("ping")
      guard result["result"] == .string("ready") else { throw WorkBenchError("WorkBench 尚未就绪") }
      print("WorkBench 本机连接正常。")
    case "key":
      try local.prepare()
      try await files.exclusively {
        var buffer = [CChar](repeating: 0, count: 512)
        guard readpassphrase("DeepSeek API Key: ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
          throw WorkBenchError("请在本机终端输入 Key")
        }
        let value = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
          as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("sk-"), value.count > 12, value.count < 200,
          value.utf8.allSatisfy({ (33...126).contains($0) }) else {
          throw WorkBenchError("DeepSeek API Key 格式不正确")
        }
        try files.save(value, to: "deepseek.json")
        print("DeepSeek Key 已保存在本机，仅当前用户可读。")
      }
    case "pair":
      try local.prepare()
      try await files.exclusively {
        let client = WeChatClient()
        let qr = try await client.makeQR()
        let image = local.directory.appendingPathComponent("pairing-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: image) }
        let png = try WeChatClient.pngQR(qr.payload)
        do { try png.write(to: image, options: .atomic) }
        catch { throw WorkBenchError("无法保存微信绑定二维码到本机助手目录") }
        _ = await MainActor.run { NSWorkspace.shared.open(image) }
        print("请用手机微信扫描二维码并在手机上确认。二维码文件：\(image.path)")
        let credential = try await client.waitForPair(id: qr.id) {
          print("请输入微信手机端显示的配对码：", terminator: " ")
          guard let pin = readLine(), (4...10).contains(pin.count),
            pin.utf8.allSatisfy({ (48...57).contains($0) })
          else { throw WorkBenchError("配对码格式不正确") }
          return pin
        }
        // Pairing intentionally starts a fresh conversation and never reuses a previous owner's data.
        try files.save(AssistantState(), to: "state.json")
        try files.save(credential, to: "wechat.json")
        print("微信已绑定。保持 WorkBench 打开，再运行 run。")
      }
    case "run":
      try await files.exclusively {
        guard let credential: WeChatCredentials = try files.load("wechat.json") else {
          throw WorkBenchError("请先运行 pair，用微信扫码绑定")
        }
        let key: String? = try files.load("deepseek.json")
        let agent = Agent(workspace: { try await local.request($0, $1) }, completion: {
          guard let key else { throw WorkBenchError("尚未配置 DeepSeek Key，请在 Mac 上运行 key") }
          return try await DeepSeekClient(key: key).complete($0)
        })
        print("微信助手已启动。发 /ping 检查连接；按 Control-C 停止。")
        try await serve(credential, agent: agent, files: files)
      }
    default: throw WorkBenchError("未知命令，请运行 workbench-assistant help")
    }
  }

  static func serve(_ credential: WeChatCredentials, agent: Agent, files: AssistantFiles, status: @Sendable (String?) async -> Void = { _ in },
    onReply: @Sendable (AgentReply) async -> Void = { _ in }) async throws {
    let client = WeChatClient(credential)
    var state = try files.load("state.json") ?? AssistantState()
    state.history = state.history.filter { $0.isRecent() }
    if state.waitingForImage != true {
      state.recentUserInstruction = nil
      state.recentUserAt = nil
    }
    try files.save(state, to: "state.json")
    var delay = 1
    while !Task.isCancelled {
      try await flush(&state, client: client, files: files)
      if let inbox = state.inbox, state.inFlight == nil, inbox.waitInterval(now: .now) == 0 {
        state.inFlight = inbox
        state.inbox = nil
        try files.save(state, to: "state.json")
      }
      if let batch = state.inFlight {
        let items = batch.items
        let requestID = batch.requestID(bot: credential.bot)
        let message = batch.latestPacket
        let context = message["context_token"].string
        var text = ""
        let images = items.filter { $0["type"].int == 2 }
        let documents = items.filter { $0["type"].int == 4 }
        var timetableFile: String?
        let reply: AgentReply
        do {
          text = try messageText(items)
          if documents.count > 1 || (!documents.isEmpty && !images.isEmpty) {
            reply = .init(text: "请一次发送一个 Excel 文件或一张课表截图。", pending: state.pending)
          } else if let document = documents.first {
            let workbook = try await WeChatClient.timetableFile(document["file_item"])
            timetableFile = workbook
            reply = try await agent.respond(to: text, image: nil, history: state.history, pending: state.pending,
              requestID: requestID, timetableFile: workbook)
          } else if text.isEmpty && images.isEmpty {
            reply = .init(text: "目前支持文字、图片和附带微信转写的语音。", pending: state.pending)
          } else if images.count > 1 {
            reply = .init(text: "请一次发一张图片。", pending: state.pending)
          } else {
            let image: String?
            let imageInstruction: String?
            if let item = images.first {
              image = try await WeChatClient.imageDataURL(item["image_item"])
              if let image { try files.cacheImage(image); state.recentImageAt = .now }
              imageInstruction = state.instructionForIncomingImage()
            } else {
              let control = text == "/ping" || text == "/pending" || text.hasPrefix("确认 ") || text.hasPrefix("取消 ")
              image = control ? nil : try files.cachedImage(since: state.recentImageAt)
              imageInstruction = nil
            }
            reply = try await agent.respond(to: text, image: image, history: state.history, pending: state.pending,
              requestID: requestID, imageInstruction: imageInstruction)
            if !text.isEmpty { state.recentImageAt = nil }
          }
        } catch {
          try Task.checkCancellation()
          reply = .init(text: "这次未能完成：\(display(error))", pending: state.pending, failed: true)
        }
        if state.firstTaskID == nil { state.firstTaskID = reply.createdTaskID }
        // Keep confirmations and their codes out of later model requests.
        state.history = state.history.filter { $0.isRecent() }
        if (reply.pending == nil || reply.pending?.isTimetable == true) && !text.hasPrefix("确认 ") && !text.hasPrefix("取消 ") && text != "/ping" {
          let user: String
          if let timetableFile {
            user = text + "\n[Excel 课表资料]\n" + timetableFile
          } else if text.isEmpty {
            user = items.contains { $0["type"].int == 3 } ? "[语音]" : "[图片]"
          } else {
            user = text
          }
          let answer = reply.pending.flatMap { $0.isTimetable ? $0.preview : nil } ?? reply.text
          state.history.append(ChatTurn(user: user, assistant: answer))
          state.history = Array(state.history.suffix(6))
        }
        if reply.waitingForImage, !text.isEmpty {
          state.waitingForImage = true
          state.recentUserAt = .now
          state.recentUserInstruction = text
        } else {
          state.waitingForImage = nil
          state.recentUserInstruction = nil
          state.recentUserAt = nil
        }
        state.pending = reply.pending
        state.handled = Array((state.handled + batch.messages.map(\.id)).suffix(512))
        state.inFlight = nil
        let digest = String(requestID.dropFirst("wechat-".count).prefix(32))
        state.outbox = .init(id: "wb-" + digest, context: context,
          runID: message["run_id"].string, text: reply.text)
        // Persist the complete batch result and outbound reply before sending.
        try files.save(state, to: "state.json")
        await onReply(reply)
        try await flush(&state, client: client, files: files)
        continue
      }

      let waiting = state.inbox?.waitInterval(now: .now)
      let updates: JSONValue
      do {
        updates = try await client.poll(state.cursor, timeout: waiting.map { max(0.2, $0) } ?? 40)
      } catch let error as WeChatAPIError where error.code == -14 {
        throw error
      } catch let error as URLError where waiting != nil && error.code == .timedOut {
        continue
      } catch {
        await status(display(error))
        try await Task.sleep(for: .seconds(delay))
        delay = min(delay * 2, 30)
        continue
      }
      await status(nil)
      delay = 1
      for message in updates["msgs"].array {
        guard let id = incomingID(message, credential, state) else { continue }
        let entry = ConversationMessage(id: id, packet: message)
        if state.inbox == nil { state.inbox = ConversationBatch(entry, now: .now) }
        else { state.inbox?.append(entry, now: .now) }
      }
      let cursor = updates["get_updates_buf"].string
      if !cursor.isEmpty { state.cursor = cursor }
      // Incoming messages and their cursor are durable before model execution.
      try files.save(state, to: "state.json")
      if updates["msgs"].array.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
    }
  }

  static func messageText(_ items: [JSONValue]) throws -> String {
    var parts: [String] = []
    for item in items {
      switch item["type"].int {
      case 1:
        parts.append(item["text_item"]["text"].string)
      case 3:
        let transcript = item["voice_item"]["text"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
          throw WorkBenchError("微信没有附上这条语音的识别文字，请转成文字再发一次。")
        }
        parts.append(transcript)
      default: break
      }
    }
    let text = parts.joined(separator: "\n")
    guard text.count <= 5000 else { throw WorkBenchError("这组消息太长，请分成几组发送。") }
    return text
  }

  private static func flush(_ state: inout AssistantState, client: WeChatClient, files: AssistantFiles) async throws {
    guard let outbox = state.outbox else { return }
    var delay = 1
    while true {
      try Task.checkCancellation()
      do {
        try await client.send(outbox.text, id: outbox.id, context: outbox.context, runID: outbox.runID)
        break
      } catch let error as WeChatAPIError {
        if error.code == -14 { throw error }
        // The server explicitly rejected this reply. Move on rather than blocking newer messages.
        print(display(error))
        break
      } catch {
        print("未收到发送回执，稍后重试。")
        try await Task.sleep(for: .seconds(delay))
        delay = min(delay * 2, 30)
      }
    }
    state.outbox = nil
    try files.save(state, to: "state.json")
  }

  static func incomingID(_ item: JSONValue, _ credential: WeChatCredentials, _ state: AssistantState) -> String? {
    guard item["message_type"].int == 1, item["from_user_id"] == .string(credential.owner),
      item["group_id"].string.isEmpty, !item["context_token"].string.isEmpty
    else { return nil }
    let id: String
    switch item["message_id"] {
    case .string(let value): id = value
    case .integer(let value): id = String(value)
    default: id = item["client_id"].string
    }
    guard !id.isEmpty, !state.handled.contains(id) else { return nil }
    return id
  }

  static func display(_ error: any Error) -> String {
    if let error = error as? WorkBenchError { return error.message }
    if let error = error as? WeChatAPIError { return error.errorDescription ?? "微信接口请求失败" }
    if let error = error as? URLError { return "网络请求失败（\(error.code.rawValue)），请检查网络" }
    return "本机连接或配置暂不可用，请确认 WorkBench 已打开，再重试。"
  }
}
#endif
