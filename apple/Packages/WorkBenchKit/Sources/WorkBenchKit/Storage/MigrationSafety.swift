import Darwin
import Foundation

#if os(macOS)
  import AppKit
#endif

public struct DataLocation: Sendable {
  public let directory: URL
  public let role: AppRole
  public init(directory: URL, role: AppRole) {
    self.directory = directory.standardizedFileURL
    self.role = role
  }
  public var workspaceURL: URL { directory.appendingPathComponent("workbench.sqlite") }
  public var photoURL: URL { directory.appendingPathComponent("photo.sqlite") }
  public static func current(role: AppRole) throws -> Self {
    #if os(macOS)
      let env = ProcessInfo.processInfo.environment
      if let path = env["WORKBENCH_DB_PATH"] {
        return .init(directory: URL(fileURLWithPath: path).deletingLastPathComponent(), role: role)
      }
      if let root = env["WORKBENCH_WORKSPACE_ROOT"] {
        return .init(
          directory: URL(fileURLWithPath: root).appendingPathComponent("data", isDirectory: true),
          role: role)
      }
    #endif
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return .init(directory: support.appendingPathComponent("WorkBench Preview"), role: role)
  }
}
// Immutable file descriptor; released only by deinit after its sole owner is dropped.
final class WriterLease: @unchecked Sendable {
  let descriptor: Int32
  init(directory: URL) throws {
    descriptor = Darwin.open(
      directory.appendingPathComponent(".workbench-writer.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw WorkBenchError("无法锁定工作区") }
    if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      Darwin.close(descriptor)
      throw WorkBenchError("工作区正被另一份 WorkBench 使用，请先退出它")
    }
    #if os(macOS)
      let bundle = Bundle.main.bundleIdentifier
      if let bundle,
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: {
          $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        })
      {
        Darwin.close(descriptor)
        throw WorkBenchError("请先退出原版 WorkBench，避免同时修改同一工作区")
      }
    #endif
  }
  deinit {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}
/// Runs on its own actor; reads originals using SQLite backup API, validates copies first.
actor MigrationSafety {
  static func prepare(_ location: DataLocation) throws -> WriterLease {
    let fm = FileManager.default
    try fm.createDirectory(at: location.directory, withIntermediateDirectories: true)
    let lease = try WriterLease(directory: location.directory)
    let marker = location.directory.appendingPathComponent("native-migration-v1.json")
    if fm.fileExists(atPath: marker.path) { return lease }
    let folder = location.directory.appendingPathComponent(
      "native-migration-backups/" + UUID().uuidString.lowercased(), isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    // Store initialization creates sibling asset directories. Keep its disposable
    // copies separate so it cannot occupy a destination reserved for real media.
    let validationDirectory = folder.appendingPathComponent(".validation", isDirectory: true)
    try fm.createDirectory(at: validationDirectory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: validationDirectory) }
    var databases: [JSONValue] = []
    let sources =
      location.role == .photoAssistant
      ? [location.photoURL] : [location.workspaceURL, location.photoURL]
    for source in sources where fm.fileExists(atPath: source.path) {
      let target = folder.appendingPathComponent(source.lastPathComponent)
      try SQLite(source, backupSource: true).backup(to: target)
      // Never run upgrades on the immutable backup itself.
      let validation = validationDirectory.appendingPathComponent(source.lastPathComponent)
      try fm.copyItem(at: target, to: validation)
      if source == location.workspaceURL {
        _ = try WorkspaceEngine(url: validation)
      } else {
        _ = try PhotoEngine(url: validation)
      }
      try require(
        try SQLite(validation, readOnly: true).rows("PRAGMA foreign_key_check").isEmpty,
        "迁移副本的关联校验失败")
      for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: validation.path + suffix) }
      databases.append(
        .object([
          "file": .string(source.lastPathComponent),
          "sha256": .string(MediaFiles.hash(try Data(contentsOf: target, options: .mappedIfSafe))),
        ]))
    }
    try fm.removeItem(at: validationDirectory)
    var media: [JSONValue] = []
    for name in location.role == .photoAssistant
      ? ["photo-attachments"] : ["attachments", "photo-attachments"]
    {
      let source = location.directory.appendingPathComponent(name)
      if fm.fileExists(atPath: source.path) {
        let destination = folder.appendingPathComponent(name)
        try fm.copyItem(at: source, to: destination)
        for file in try fm.contentsOfDirectory(
          at: destination, includingPropertiesForKeys: [.isRegularFileKey])
        where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
          media.append(
            .object([
              "file": .string(name + "/" + file.lastPathComponent),
              "sha256": .string(
                MediaFiles.hash(try Data(contentsOf: file, options: .mappedIfSafe))),
            ]))
        }
      }
    }
    let manifest = JSONValue.object([
      "version": .integer(1), "at": .string(Clock.stamp()),
      "role": .string(location.role.rawValue), "databases": .array(databases),
      "media": .array(media), "backup": .string(folder.path),
    ])
    try manifest.data().write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    try manifest.data().write(to: marker, options: .atomic)
    return lease
  }
}
