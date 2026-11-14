import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaOwner: Sendable {
  case task(String)
  case note(String)
  case project(String)
  case learning(String)
  case course(String)
  var field: String {
    switch self {
    case .task: "task_id"
    case .note: "note_id"
    case .project: "project_id"
    case .learning: "learning_id"
    case .course: "course_id"
    }
  }
  var id: String {
    switch self {
    case .task(let id), .note(let id), .project(let id), .learning(let id), .course(let id): id
    }
  }
}
enum MediaFiles {
  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func safeKey(_ key: String) throws {
    try require(
      key.range(
        of: "^[0-9a-fA-F-]{36}\\.(png|jpg|webp|gif|heic|avif|mp4|mov|webm)$",
        options: .regularExpression) != nil && UUID(uuidString: String(key.prefix(36))) != nil,
      "附件名称不正确")
  }
  static func remove(_ key: String, in folder: URL) throws {
    try safeKey(key)
    let url = folder.appendingPathComponent(key)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
  static func validate(_ p: JSONValue, directory: URL, maximum: Int64) throws {
    try safeKey(p["file_key"].string)
    _ = try Validation.integer(p["size"], 1...maximum)
    let url = directory.appendingPathComponent(p["file_key"].string)
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
      data.count == p["size"].int, hash(data) == p["sha256"].string
    else { throw WorkBenchError("附件缺失或校验失败，请重新同步") }
  }
  static func write(_ data: Data, name: String, directory: URL, maximum: Int, imagesOnly: Bool)
    throws -> Record
  {
    try require(!data.isEmpty && data.count <= maximum, "附件超过允许大小")
    let ext: String
    let mime: String
    if let source = CGImageSourceCreateWithData(data as CFData, nil),
      let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
      type.conforms(to: .image)
    {
      // Decode metadata only here; thumbnails are generated off the main actor.
      guard CGImageSourceGetCount(source) > 0 else { throw WorkBenchError("图片无法读取") }
      ext =
        type.conforms(to: .jpeg)
        ? "jpg"
        : type.preferredFilenameExtension == "heif"
          ? "heic" : type.preferredFilenameExtension ?? "png"
      mime = type.preferredMIMEType ?? "image/png"
    } else {
      try require(!imagesOnly, "请选择有效的订单截图")
      let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
      try require(["mp4", "mov", "webm"].contains(suffix), "仅支持图片或视频")
      ext = suffix
      mime = suffix == "mov" ? "video/quicktime" : suffix == "webm" ? "video/webm" : "video/mp4"
    }
    let id = UUID().uuidString.lowercased()
    let key = id + "." + ext
    try safeKey(key)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent(key), options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(key).path)
    return [
      "id": .string(id), "file_key": .string(key), "mime": .string(mime),
      "name": .string(String(name.prefix(255))), "size": .integer(Int64(data.count)),
      "sha256": .string(hash(data)), "created_at": .string(Clock.stamp()),
    ]
  }
}
extension PhotoEngine {
  func importImage(data: Data, name: String, orderID: String) throws -> MediaAttachment {
    try require(UUID(uuidString: orderID) != nil, "订单 ID 不正确")
    var fields = try MediaFiles.write(
      data, name: name, directory: assets, maximum: 20 * 1024 * 1024, imagesOnly: true)
    fields["order_id"] = .string(orderID)
    fields["deleted_at"] = .null
    do {
      try put(
        "attachment:" + fields.identifier, kind: "attachment", orderID: orderID,
        payload: .object(fields), published: false)
      try bump()
    } catch {
      try? MediaFiles.remove(fields.text("file_key"), in: assets)
      throw error
    }
    return MediaAttachment(fields: fields)
  }
}
extension WorkspaceDatabase {
  public func importAttachment(data: Data, name: String, owner: MediaOwner) throws
    -> MediaAttachment
  { try engineImport(data: data, name: name, owner: owner) }
}
