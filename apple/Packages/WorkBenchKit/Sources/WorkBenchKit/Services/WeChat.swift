#if os(macOS)
import CommonCrypto
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Wire format reference: Tencent/openclaw-weixin, src/api and src/auth/login-qr.ts.
// This client has no dependency on the OpenClaw runtime or npm.
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection
    response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

let assistantHTTP: URLSession = {
  let config = URLSessionConfiguration.ephemeral
  config.timeoutIntervalForResource = 65
  return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
}()

struct WeChatCredentials: Codable, Sendable {
  let base: URL
  let token: String
  let bot: String
  let owner: String
}

struct WeChatAPIError: LocalizedError {
  let code: Int64
  var errorDescription: String? {
    code == -14 ? "微信会话已过期，请重新扫码绑定" : "微信接口返回错误（\(code)）"
  }
}

/// iLink uses uint64 IDs. Do not round large IDs through JSONValue.number (Double).
private struct WireUpdates: Decodable {
  struct Message: Decodable {
    enum Key: String, CodingKey { case messageID = "message_id" }
    var packet: JSONValue
    init(from decoder: any Decoder) throws {
      packet = try JSONValue(from: decoder)
      if case .object = packet,
        let id = try? decoder.container(keyedBy: Key.self).decode(UInt64.self, forKey: .messageID)
      { packet["message_id"] = .string(String(id)) }
    }
  }
  let msgs: [Message]?
}

struct WeChatClient: Sendable {
  static let defaultBase = URL(string: "https://ilinkai.weixin.qq.com")!
  private let credentials: WeChatCredentials?
  init(_ credentials: WeChatCredentials? = nil) { self.credentials = credentials }

  func makeQR() async throws -> (id: String, payload: String) {
    let result = try await request("get_bot_qrcode", base: Self.defaultBase,
      query: [.init(name: "bot_type", value: "3")], payload: ["local_token_list": .array([])])
    let id = result["qrcode"].string, payload = result["qrcode_img_content"].string
    guard !id.isEmpty, !payload.isEmpty else { throw WorkBenchError("微信未返回可用的绑定二维码") }
    return (id, payload)
  }

  func waitForPair(id: String, isolation: isolated (any Actor)? = #isolation, onScan: () async -> Void = {}, askPIN: () async throws -> String) async throws -> WeChatCredentials {
    var base = Self.defaultBase
    var pin: String?
    let until = ContinuousClock.now + .seconds(160)
    while ContinuousClock.now < until {
      try Task.checkCancellation()
      var query = [URLQueryItem(name: "qrcode", value: id)]
      if let pin { query.append(.init(name: "verify_code", value: pin)) }
      let packet: JSONValue
      do { packet = try await request("get_qrcode_status", base: base, query: query, timeout: 32) }
      catch let error as URLError where error.code == .timedOut { continue }
      pin = nil
      switch packet["status"].string {
      case "confirmed":
        let finalBase = packet["baseurl"].string.isEmpty ? base : URL(string: packet["baseurl"].string)
        let token = packet["bot_token"].string, owner = packet["ilink_user_id"].string
        let bot = packet["ilink_bot_id"].string
        guard let finalBase, Self.trusted(finalBase), !token.isEmpty, !owner.isEmpty, !bot.isEmpty else {
          throw WorkBenchError("绑定缺少安全凭据或无法识别扫码用户，已停止")
        }
        return .init(base: finalBase, token: token, bot: bot, owner: owner)
      case "scaned_but_redirect":
        guard let redirect = URL(string: "https://" + packet["redirect_host"].string),
          Self.trusted(redirect) else { throw WorkBenchError("微信返回了无法识别的绑定地址") }
        base = redirect
      case "need_verifycode", "confirmed_but_need_verifycode":
        pin = try await askPIN()
      case "expired": throw WorkBenchError("微信绑定二维码已过期，请重新发起绑定")
      case "verify_code_blocked": throw WorkBenchError("微信已停止校验配对码，请重新发起绑定")
      case "binded_redirect": throw WorkBenchError("微信返回已有绑定，未发放新的连接凭据")
      case "scaned": await onScan()
      case "wait": break
      default: throw WorkBenchError("微信返回了当前版本尚不支持的绑定状态")
      }
      try await Task.sleep(for: .seconds(1))
    }
    throw WorkBenchError("绑定超时，请重新生成二维码")
  }

  func poll(_ cursor: String, timeout: TimeInterval = 40) async throws -> JSONValue {
    try await request("getupdates", base: try bound().base,
      payload: ["get_updates_buf": .string(cursor)], timeout: timeout)
  }

  func send(_ text: String, id: String, context: String, runID: String?) async throws {
    let credential = try bound()
    let item: JSONValue = .object(["type": .integer(1), "text_item": .object(["text": .string(text)])])
    var message: Record = [
      "from_user_id": .string(""), "to_user_id": .string(credential.owner),
      "client_id": .string(id), "message_type": .integer(2), "message_state": .integer(2),
      "item_list": .array([item]), "context_token": .string(context),
    ]
    if let runID, !runID.isEmpty { message["run_id"] = .string(runID) }
    _ = try await request("sendmessage", base: credential.base, payload: ["msg": .object(message)])
  }

  private func bound() throws -> WeChatCredentials {
    guard let credentials else { throw WorkBenchError("请先扫码绑定微信") }
    return credentials
  }

  private func request(_ endpoint: String, base: URL, query: [URLQueryItem] = [],
    payload: Record? = nil, timeout: TimeInterval = 15
  ) async throws -> JSONValue {
    guard Self.trusted(base), var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      throw WorkBenchError("不支持此微信服务地址")
    }
    parts.path = "/ilink/bot/" + endpoint
    parts.queryItems = query.isEmpty ? nil : query
    guard let url = parts.url else { throw WorkBenchError("微信请求地址不正确") }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("bot", forHTTPHeaderField: "iLink-App-Id")
    // Version of the published wire format used as reference.
    req.setValue("196608", forHTTPHeaderField: "iLink-App-ClientVersion")
    if let payload {
      req.httpMethod = "POST"
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.setValue("ilink_bot_token", forHTTPHeaderField: "AuthorizationType")
      req.setValue(Data(String(UInt32.random(in: .min ... .max)).utf8).base64EncodedString(),
        forHTTPHeaderField: "X-WECHAT-UIN")
      var body = payload
      body["base_info"] = .object(["channel_version": .string("3.0.0-beta-0"),
        "bot_agent": .string("WorkBenchAssistant/0.1")])
      req.httpBody = try JSONValue.object(body).data()
    }
    if let token = credentials?.token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await assistantHTTP.data(for: req)
    guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
      throw WorkBenchError("微信请求未成功（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
    }
    let decoded: JSONValue
    do { decoded = try JSONValue(data: data) }
    catch { throw WorkBenchError("微信接口 \(endpoint) 返回了无法读取的数据（\(data.count) 字节）") }
    var result = decoded
    guard case .object = result else { throw WorkBenchError("微信返回了未知格式") }
    let code = result["errcode"].int != 0 ? result["errcode"].int : result["ret"].int
    if code != 0 { throw WeChatAPIError(code: code) }
    if endpoint == "getupdates" {
      result["msgs"] = .array(try JSONDecoder().decode(WireUpdates.self, from: data).msgs?.map(\.packet) ?? [])
    }
    return result
  }

  static func trusted(_ url: URL) -> Bool {
    url.scheme == "https" && url.host()?.hasSuffix(".weixin.qq.com") == true
      && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
  }

  static func imageDataURL(_ image: JSONValue) async throws -> String {
    let data = try await mediaBytes(image)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source), let mime = UTType(type as String)?.preferredMIMEType,
      ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mime)
    else { throw WorkBenchError("这张图片无法读取，请发 JPEG、PNG、GIF 或 WebP") }
    return "data:\(mime);base64,\(data.base64EncodedString())"
  }

  static func timetableFile(_ file: JSONValue) async throws -> String {
    guard file["file_name"].string.lowercased().hasSuffix(".xlsx") else {
      throw WorkBenchError("课表文件请保存为 Excel .xlsx，或发送清晰的截图")
    }
    return try await TimetableWorkbook.read(mediaBytes(file))
  }

  private static func mediaBytes(_ item: JSONValue) async throws -> Data {
    let media = item["media"]
    var components = URLComponents(string: "https://novac2c.cdn.weixin.qq.com/c2c/download")!
    let param = media["encrypt_query_param"].string
    components.queryItems = [.init(name: "encrypted_query_param", value: param)]
    let full = URL(string: media["full_url"].string).flatMap { trusted($0) ? $0 : nil }
    guard let url = full ?? (param.isEmpty ? nil : components.url) else {
      throw WorkBenchError("这个微信附件没有可用的下载地址")
    }
    let limit = 8 * 1024 * 1024
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do { (bytes, response) = try await assistantHTTP.bytes(for: URLRequest(url: url, timeoutInterval: 25)) }
    catch let error as URLError where error.code == .timedOut {
      throw WorkBenchError("微信附件下载超时，请重新发送。")
    }
    guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= Int64(limit)
    else { throw WorkBenchError("无法下载附件，或附件超过 8 MB") }
    var data = Data()
    for try await byte in bytes {
      guard data.count < limit else { throw WorkBenchError("附件超过 8 MB") }
      data.append(byte)
    }
    let rawKey = item["aeskey"].string
    let key = media["aes_key"].string
    if !rawKey.isEmpty || !key.isEmpty {
      let decoded = !rawKey.isEmpty ? Data(rawKey.utf8) : Data(base64Encoded: key)
      guard let decoded else { throw WorkBenchError("附件密钥格式不正确") }
      data = try decrypt(data, key: decoded.count == 16 ? decoded : hexKey(decoded))
    }
    return data
  }

  private static func hexKey(_ data: Data) throws -> Data {
    let chars = Array(data)
    guard chars.count == 32 else { throw WorkBenchError("图片密钥长度不正确") }
    var key = Data()
    for index in stride(from: 0, to: 32, by: 2) {
      guard let value = UInt8(String(decoding: chars[index...index + 1], as: UTF8.self), radix: 16)
      else { throw WorkBenchError("图片密钥格式不正确") }
      key.append(value)
    }
    return key
  }

  static func decrypt(_ ciphertext: Data, key: Data) throws -> Data {
    guard key.count == 16 else { throw WorkBenchError("图片密钥长度不正确") }
    var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
    let capacity = plaintext.count
    var written = 0
    let status = plaintext.withUnsafeMutableBytes { out in
      ciphertext.withUnsafeBytes { input in
        key.withUnsafeBytes { secret in
          CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), secret.baseAddress,
            key.count, nil, input.baseAddress, ciphertext.count, out.baseAddress, capacity, &written)
        }
      }
    }
    guard status == kCCSuccess else { throw WorkBenchError("无法解密微信图片") }
    return plaintext.prefix(written)
  }

  static func pngQR(_ text: String) throws -> Data {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw WorkBenchError("无法生成二维码") }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    guard let qr = filter.outputImage else { throw WorkBenchError("无法生成二维码") }
    let canvas = qr.composited(over: CIImage(color: .white)).cropped(to: qr.extent.insetBy(dx: -4, dy: -4))
      .transformed(by: .init(scaleX: 8, y: 8))
    guard let png = CIContext().pngRepresentation(of: canvas, format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw WorkBenchError("无法显示二维码") }
    return png
  }
}
#endif
