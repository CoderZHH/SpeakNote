#if os(macOS)
  import Foundation
  import Darwin

  public actor ChromeService {
    public static let shared = ChromeService()
    public enum Operation: Sendable { case open, reset, retire }
    public func operate(_ operation: Operation, account: WorkspaceItem, directory: URL) async throws
    {
      let id = account.id
      try require(
        id.count <= 100
          && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") },
        "账号 ID 不正确")
      let root =
        ProcessInfo.processInfo.environment["WORKBENCH_SESSION_ROOT"].map {
          URL(fileURLWithPath: $0)
        } ?? directory.appendingPathComponent("account-sessions")
      if operation == .retire {
        let folder = root.appendingPathComponent(MediaFiles.hash(Data(id.utf8)))
        try FileManager.default.createDirectory(
          at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("removed".utf8).write(
          to: folder.appendingPathComponent(".retired"), options: .atomic)
        if (try? request(root, route: "/health")) != nil {
          _ = try request(root, route: "/close", body: .object(["id": .string(id)]))
        }
        return
      }
      if (try? request(root, route: "/health")) == nil {
        try require(
          FileManager.default.fileExists(
            atPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
          "请先安装 Google Chrome")
        guard let resources = Bundle.main.resourceURL else { throw WorkBenchError("账号工具资源不可用") }
        let node = resources.appendingPathComponent(
          "ChromeRuntime/backend.bundle/Contents/MacOS/workbench-node")
        let runtime = resources.appendingPathComponent("ChromeRuntime/runtime")
        try require(
          FileManager.default.isExecutableFile(atPath: node.path),
          "账号工具尚未打包，请运行 apple/prepare-chrome.sh")
        let process = Process()
        process.executableURL = node
        process.arguments = [runtime.appendingPathComponent("src/server.mjs").path]
        process.currentDirectoryURL = runtime
        var env = ProcessInfo.processInfo.environment
        env["WORKBENCH_SESSION_ROOT"] = root.path
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var ready = false
        for _ in 0..<120 {
          if (try? request(root, route: "/health")) != nil {
            ready = true
            break
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        try require(ready, "账号工具启动失败，请重试")
      }
      _ = try request(
        root, route: operation == .reset ? "/reset" : "/open",
        body: .object(["id": .string(id), "platform": account[.platform]]))
    }
    private func request(_ root: URL, route: String, body: JSONValue? = nil) throws -> JSONValue {
      let socketPath =
        "/tmp/workbench-accounts-" + MediaFiles.hash(Data(root.path.utf8)).prefix(20) + ".sock"
      let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw WorkBenchError("账号连接不可用") }
      defer { Darwin.close(fd) }
      var timeout = timeval(tv_sec: 46, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      var noPipe: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      let bytes = Array(socketPath.utf8) + [0]
      try require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path), "账号工具地址过长")
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
      let connected = withUnsafePointer(to: &address) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      try require(connected == 0, "账号工具尚未连接")
      let payload = try body?.json() ?? ""
      let method = body == nil ? "GET" : "POST"
      let data = Data(
        "\(method) \(route) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)"
          .utf8)
      try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
          try require(n > 0, "账号请求失败")
          offset += n
        }
      }
      var raw = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let n = Darwin.read(fd, &buffer, buffer.count)
        try require(n >= 0 && raw.count <= 1_000_000, "账号工具响应失败")
        if n == 0 { break }
        raw.append(contentsOf: buffer.prefix(n))
      }
      let text = String(decoding: raw, as: UTF8.self)
      guard let split = text.range(of: "\r\n\r\n") else { throw WorkBenchError("账号工具响应格式不正确") }
      let result = try JSONValue(json: String(text[split.upperBound...]))
      try require(
        text.hasPrefix("HTTP/1.1 200"),
        result["error"].string.isEmpty ? "后台未能打开" : result["error"].string)
      return result
    }
  }
#endif
